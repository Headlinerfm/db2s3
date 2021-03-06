require File.dirname(__FILE__) + '/spec_helper'

describe 'db2s3' do
  def load_schema
    `cat '#{File.dirname(__FILE__) + '/mysql_schema.sql'}' | mysql -u #{DBConfig[:user]} #{DBConfig[:database]}`
  end

  def drop_schema
    `cat '#{File.dirname(__FILE__) + '/mysql_drop_schema.sql'}' | mysql -u #{DBConfig[:user]} #{DBConfig[:database]}`
  end

  class Person < ActiveRecord::Base
  end

  if DB2S3::Config.const_defined?('S3')
    it 'can save and restore a backup to S3' do
      db2s3 = DB2S3.new
      load_schema
      Person.create!(:name => "Baxter")
      db2s3.full_backup
      drop_schema
      db2s3.restore
      Person.find_by_name("Baxter").should_not be_nil
    end
  end
  
  if DB2S3::Config::S3[:backup_binlog]
     it 'can save and restore a backup to and from S3 with incremental backups' do
       db2s3 = DB2S3.new
       load_schema
       Person.create!(:name => "Baxter")
       db2s3.full_backup
       sleep(10)
       Person.create!(:name => "Nimrod")
       db2s3.incremental_backup
       drop_schema
       db2s3.restore
       Person.find_by_name("Nimrod").should_not be_nil
     end
   end
end
