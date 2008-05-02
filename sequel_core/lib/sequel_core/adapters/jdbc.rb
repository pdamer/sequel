require 'java'

module Sequel
  module JDBC
    module JavaLang; include_package 'java.lang'; end
    module JavaSQL; include_package 'java.sql'; end
    
    def self.load_driver(driver)
      JavaLang::Class.forName(driver)
      # "com.mysql.jdbc.Driver"
    end
    
    class Database < Sequel::Database
      set_adapter_scheme :jdbc
      
      def connect
        unless conn_string = @opts[:uri] || @opts[:url] || @opts[:database]
          raise Error, "No connection string specified"
        end
        unless conn_string =~ /^jdbc:/
          conn_string = "jdbc:#{conn_string}"
        end
        JavaSQL::DriverManager.getConnection(
          conn_string, 
          @opts[:user], 
          @opts[:password]
        )
        # "jdbc:mysql://127.0.0.1:3306/ruby?user=root"
        # "mysql://127.0.0.1:3306/ruby?user=root"
      end
      
      def disconnect
        @pool.disconnect {|c| c.close}
      end
    
      def dataset(opts = nil)
        JDBC::Dataset.new(self, opts)
      end
      
      def execute_and_forget(sql)
        @logger.info(sql) if @logger
        @pool.hold do |conn|
          stmt = conn.createStatement
          begin
            stmt.executeQuery(sql)
          ensure
            stmt.close
          end
        end
      end
      
      def execute(sql)
        @logger.info(sql) if @logger
        @pool.hold do |conn|
          stmt = conn.createStatement
          begin
            yield stmt.executeQuery(sql)
          ensure
            stmt.close
          end
        end
      end
    end
    
    class Dataset < Sequel::Dataset
      def literal(v)
        case v
        when Time
          literal(v.iso8601)
        else
          super
        end
      end

      def fetch_rows(sql, &block)
        @db.synchronize do
          @db.execute(sql) do |result|
            # get column names
            meta = result.getMetaData
            column_count = meta.getColumnCount
            @columns = []
            @column_type_converters = []
            1.upto(column_count) do |i|
              @columns << meta.getColumnName(i).to_sym
              @column_type_converters << get_column_type_converter(meta.getColumnType(i), meta.getScale(i))
            end

            # get rows
            while result.next
              row = {}
              @columns.each_with_index do |column, i| 
                row[column] = @column_type_converters[i].call(result, i+1)
              end
              
              yield row
            end
          end
        end
        self
      end
      
      #code adapted from the jdbc_adapter for activerecord.
      def get_column_type_converter(type, scale)
        if scale != 0
          proc { |result, col_index|
            decimal = result.getString(col_index)
            decimal.to_f
          }
        else
          case type
          when JavaSQL::Types::CHAR, JavaSQL::Types::VARCHAR, JavaSQL::Types::LONGVARCHAR
            proc { |result, col_index| result.getString(col_index) }
          when JavaSQL::Types::SMALLINT, JavaSQL::Types::INTEGER, JavaSQL::Types::NUMERIC, JavaSQL::Types::BIGINT
            proc { |result, col_index| result.getInt(col_index) }
          when JavaSQL::Types::BIT, JavaSQL::Types::BOOLEAN, JavaSQL::Types::TINYINT
            proc { |result, col_index| result.getBoolean(col_index) }
          when JavaSQL::Types::TIMESTAMP
            proc { |result, col_index| to_ruby_time(result.getTimestamp(col_index)) }
          when JavaSQL::Types::TIME
            proc { |result, col_index| to_ruby_time(result.getTime(col_index)) }
          when JavaSQL::Types::DATE
            proc { |result, col_index| to_ruby_time(result.getDate(col_index)) }
          else
            proc { |result, col_index|
              types = JavaSQL::Types.constants
              name = types.find {|t| JavaSQL::Types.const_get(t.to_sym) == type}
              raise "jdbc: type #{name} not supported yet"
            }
          end
        end
      end
        
      def to_ruby_time(java_date)
        if java_date
          tm = java_date.getTime
          Time.at(tm / 1000, (tm % 1000) * 1000)
        end
      end
      
      
      def insert(*values)
        @db.execute_and_forget insert_sql(*values)
      end
    
      def update(*args, &block)
        @db.execute_and_forget update_sql(*args, &block)
      end
    
      def delete(opts = nil)
        @db.execute_and_forget delete_sql(opts)
      end
    
      # Formats a SELECT statement using the given options and the dataset
      # options.
      # Stolen from oracle.rb
      def select_sql(opts = nil)
        opts = opts ? @opts.merge(opts) : @opts

        if sql = opts[:sql]
          return sql
        end

        columns = opts[:select]
        select_columns = columns ? column_list(columns) : WILDCARD
        sql = opts[:distinct] ? \
        "SELECT DISTINCT #{select_columns}" : \
        "SELECT #{select_columns}"
      
        if opts[:from]
          sql << " FROM #{source_list(opts[:from])}"
        end
      
        if join = opts[:join]
          sql << join
        end

        if where = opts[:where]
          sql << " WHERE #{where}"
        end

        if group = opts[:group]
          sql << " GROUP BY #{column_list(group)}"
        end

        if having = opts[:having]
          sql << " HAVING #{having}"
        end

        if union = opts[:union]
          sql << (opts[:union_all] ? \
            " UNION ALL #{union.sql}" : " UNION #{union.sql}")
        elsif intersect = opts[:intersect]
          sql << (opts[:intersect_all] ? \
            " INTERSECT ALL #{intersect.sql}" : " INTERSECT #{intersect.sql}")
        elsif except = opts[:except]
          sql << (opts[:except_all] ? \
            " EXCEPT ALL #{except.sql}" : " EXCEPT #{except.sql}")
        end

        if order = opts[:order]
          sql << " ORDER BY #{column_list(order)}"
        end

        if limit = opts[:limit]
          if (offset = opts[:offset]) && (offset > 0)
            sql = "SELECT * FROM (SELECT raw_sql_.*, ROWNUM raw_rnum_ FROM(#{sql}) raw_sql_ WHERE ROWNUM <= #{limit + offset}) WHERE raw_rnum_ > #{offset}"
          else
            sql = "SELECT * FROM (#{sql}) WHERE ROWNUM <= #{limit}"
          end
        end

        sql
      end

      alias sql select_sql
    end
  end
end