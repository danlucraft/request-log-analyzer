require 'rubygems'
require 'activerecord'

module RequestLogAnalyzer::Aggregator

  # The database aggregator will create an SQLite3 database with all parsed request information.
  #
  # The prepare method will create a database schema according to the file format definitions.
  # It will also create ActiveRecord::Base subclasses to interact with the created tables. 
  # Then, the aggregate method will be called for every parsed request. The information of
  # these requests is inserted into the tables using the ActiveRecord classes.
  #
  # A requests table will be created, in which a record is inserted for every parsed request.
  # For every line type, a separate table will be created with a request_id field to point to
  # the request record, and a field for every parsed value. Finally, a warnings table will be
  # created to log all parse warnings.
  class Database < Base

    # Establishes a connection to the database and creates the necessary database schema for the
    # current file format
    def prepare(source)
      if options[:database] =~ /\.(yml|yaml)$/
        db_config = YAML.load(File.read(options[:database]))
        ActiveRecord::Base.establish_connection(db_config)
      else
        ActiveRecord::Base.establish_connection(:adapter => 'sqlite3', :database => options[:database])
      end
      # File.unlink(options[:database]) if File.exist?(options[:database]) # TODO: keep old database?
      create_database_schema!
      if source.is_a?(RequestLogAnalyzer::Source::LogParser)
        source.existing_files = files
      end
    end
    
    # Aggregates a request into the database
    # This will create a record in the requests table and create a record for every line that has been parsed,
    # in which the captured values will be stored.
    def aggregate(request, earliest_uncommitted_line, earliest_uncommitted_pos)
      @request_object = @request_class.new(:first_lineno => request.first_lineno, :last_lineno => request.last_lineno)
      request.lines.each do |line|
        class_columns = @orm_module.const_get("#{line[:line_type]}_line".classify).column_names.reject { |column| ['id'].include?(column) }
        attributes = Hash[*line.select { |(k, v)| class_columns.include?(k.to_s) }.flatten]
        file = file_from_filename(line[:filename])
        file.last_lineno = earliest_uncommitted_line
        file.last_pos    = earliest_uncommitted_pos
        attributes = attributes.merge(:file_id => file.id)
        @request_object.hashed_value = line[:hash]
        @request_object.send("#{line[:line_type]}_lines").build(attributes)
      end
      # unless @request_class.exists?(:hashed_value => @request_object.hashed_value)
        @request_object.save!
      # end
    rescue SQLite3::SQLException => e
      raise Interrupt, e.message
    rescue SQLite3::BusyException => e
      puts "Database busy, waiting...."
      sleep 0.3
      retry
    end
    
    # Finalizes the aggregator by closing the connection to the database
    def finalize
      @request_count = @orm_module::Request.count
      files.each {|_, file| file.save }
      ActiveRecord::Base.remove_connection
    end
    
    # Records w warining in the warnings table.
    def warning(type, message, lineno)
      @orm_module::Warning.create!(:warning_type => type.to_s, :message => message, :lineno => lineno)
    end
    
    # Prints a short report of what has been inserted into the database
    def report(output)
      output.title('Request database created')
      
      output <<  "A database file has been created with all parsed request information.\n"
      output <<  "#{@request_count} requests have been added to the database.\n"      
      output <<  "To execute queries on this database, run the following command:\n"
      output <<  output.colorize("  $ sqlite3 #{options[:database]}\n", :bold)
      output << "\n"
    end
    
    # Returns a hash of filename => file from the database.
    def files
      if @file_class
        @files ||= begin
          result = {}
          @file_class.all.each {|file| result[file.filename] = file}
          result
        end
      end
    end

    protected 
    
    # This function creates a database table for a given line definition.
    # It will create a field for every capture in the line, and adds a lineno field to indicate at
    # what line in the original file the line was found, and a request_id to link lines related
    # to the same request. It will also create an index in the request_id field to speed up queries.
    def create_database_table(name, definition)
      ActiveRecord::Migration.verbose = options[:debug]
      table_name = "#{name}_lines"
      return if ActiveRecord::Base.connection.tables.include?(table_name)
      ActiveRecord::Migration.create_table(table_name) do |t|
        t.column(:request_id, :integer)
        t.column(:lineno,     :integer)
        t.column(:file_id,    :integer)
        
        definition.captures.each do |capture|
          # Add a field for every capture
          t.column(capture[:name], column_type(capture[:type]))
          
          # If the capture provides other field as well, create them too
          if capture[:provides].kind_of?(Hash)
            capture[:provides].each do |field, field_type|
              t.column(field, column_type(field_type))
            end
          end
        end
      end
      definition.captures.each do |capture|
        if capture[:index]
          ActiveRecord::Migration.add_index("#{name}_lines", [capture[:name]])
        end
      end
      ActiveRecord::Migration.add_index("#{name}_lines", [:request_id])
    end
    
    # Creates an ActiveRecord class for a given line definition.
    # A subclass of ActiveRecord::Base is created and an association with the Request class is
    # created using belongs_to / has_many. This association will later be used to create records
    # in the corresponding table. This table should already be created before this method is called.
    def create_activerecord_class(name, definition)
      class_name = "#{name}_line".camelize
      klass = Class.new(ActiveRecord::Base)
      klass.send(:belongs_to, :request)
      
      definition.captures.each do |capture|
        klass.send(:serialize, capture[:name], Hash) if capture[:provides]
      end
      
      @orm_module.const_set(class_name, klass) unless @orm_module.const_defined?(class_name)
      @request_class.send(:has_many, "#{name}_lines".to_sym)
    end    
    
    # Creates a files table, which stores a row for each filename imported into the database.
    def create_files_table_and_class
      unless ActiveRecord::Base.connection.tables.include?("files")
        ActiveRecord::Migration.verbose = options[:debug]
        ActiveRecord::Migration.create_table("files") do |t|
          t.string  :filename
          t.integer :last_lineno, :default => 0
          t.integer :last_pos
        end
      end
      @file_class = @orm_module.const_set('File', Class.new(ActiveRecord::Base))
    end
    
    # Creates a requests table, in which a record is created for every request. It also creates an
    # ActiveRecord::Base class to communicate with this table.
    def create_request_table_and_class
      unless ActiveRecord::Base.connection.tables.include?("requests")
        ActiveRecord::Migration.verbose = options[:debug]
        ActiveRecord::Migration.create_table("requests") do |t|
          t.integer :first_lineno
          t.integer :last_lineno
          t.string  :hashed_value
        end    
        # ActiveRecord::Migration.add_index("requests", [:hashed_value])
      end
      
      @orm_module.const_set('Request', Class.new(ActiveRecord::Base)) unless @orm_module.const_defined?('Request')     
      @request_class = @orm_module.const_get('Request')
    end

    # Creates a warnings table and a corresponding Warning class to communicate with this table using ActiveRecord.
    def create_warning_table_and_class
      unless ActiveRecord::Base.connection.tables.include?("warnings")
        ActiveRecord::Migration.verbose = options[:debug]
        ActiveRecord::Migration.create_table("warnings") do |t|
          t.string  :warning_type, :limit => 30, :null => false
          t.string  :message
          t.integer :lineno          
        end    
      end
      
      @orm_module.const_set('Warning', Class.new(ActiveRecord::Base)) unless @orm_module.const_defined?('Warning')
    end
    
    # Creates the database schema and related ActiveRecord::Base subclasses that correspond to the 
    # file format definition. These ORM classes will later be used to create records in the database.
    def create_database_schema!
      if file_format.class.const_defined?('Database')
        @orm_module = file_format.class.const_get('Database')
      else
        @orm_module = file_format.class.const_set('Database', Module.new)
      end
      
      create_request_table_and_class
      create_warning_table_and_class
      create_files_table_and_class
      
      file_format.line_definitions.each do |name, definition|
        create_database_table(name, definition)
        create_activerecord_class(name, definition)
      end
    end
    
    # Returns the file for the given filename. If one doesn't
    # exist it will create one in the database.
    def file_from_filename(filename)
      unless file = files[filename]
        file = @file_class.create(:filename => filename)
        files[file.filename] = file
      end
      file
    end
    
    # Function to determine the column type for a field
    # TODO: make more robust / include in file-format definition
    def column_type(type_indicator)
      case type_indicator
      when :eval;      :text
      when :text;      :text
      when :string;    :string
      when :sec;       :double
      when :msec;      :double
      when :duration;  :double
      when :float;     :double
      when :double;    :double
      when :integer;   :integer
      when :int;       :int
      when :timestamp; :datetime
      when :datetime;  :datetime
      when :date;      :date
      else             :string
      end
    end
  end
end
