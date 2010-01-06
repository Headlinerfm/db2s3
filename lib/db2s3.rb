require 'activesupport'
require 'aws/s3'
require 'tempfile'
require 'lockfile'
require 'tmpdir'

class DB2S3
  class Config
  end

  def initialize
  end

  def full_backup(mysqldump_path = nil)
    begin
      Lockfile.new('db2s3_backup.lock', :retries => 0) do
        file_name = "dump-#{db_credentials[:database]}-#{Time.now.utc.strftime("%Y%m%d%H%M")}.sql.gz"
        unless mysqldump_path.nil?
          store.store(file_name, open(dump_db(mysqldump_path).path))
        else
          store.store(file_name, open(dump_db.path))
        end
        if binlog_path
          delete_all_binlogs #otherwise restore will use old data in binlogs
        end
      end
    rescue Lockfile::MaxTriesLockError => e
      raise("error, another backup is in progress, exiting.")
    end
  end

  def incremental_backup
    if binlog_path
      begin
         Lockfile.new('db2s3_backup.lock', :retries => 0) do
             execute_sql "flush logs"
             logs = Dir.glob("#{binlog_path}mysql-bin.[0-9]*").sort
             logs_to_archive = logs[0..-2] # all logs except the last
             logs_to_archive.each do |log|
               # The following executes once for each filename in logs_to_archive
               file_name=File.basename(log).gsub!('.','-')
               log_name="incremental-#{db_credentials[:database]}-"+file_name+"-#{Time.now.utc.strftime("%Y%m%d%H%M")}.log"
               store.store(log_name, open(log))   
             end
             store.store(most_recent_inc_dump_file_name, "#{Time.now.utc}")
             execute_sql "purge master logs to '#{File.basename(logs[-1])}'"
         end
      rescue Lockfile::MaxTriesLockError => e
         raise("error, another backup is in progress, exiting.")
      end
    else
      raise("error, incremental backups not configured, please specify binlog_path")
    end
  end

  def restore
    begin
      Lockfile.new('db2s3_restore.lock', :retries => 0) do
        dump_file_name = store.fetch(most_recent_dump_file_name).read
        file = store.fetch(dump_file_name)
        run "gunzip -c #{file.path} | mysql #{mysql_options}"
        if DB2S3::Config::S3[:backup_binlog] == true
          incremental_restore
        end
      end
    rescue Lockfile::MaxTriesLockError => e
      raise("error, another restore is in progress, exiting.")
    end
  end
  
  def incremental_restore
    begin
      Lockfile.new('db2s3_incremental_restore.lock', :retries => 0) do
        filelist = store.list
        incremental_files = filelist.select{|file|file.include?('mysql-bin')}.collect do |file|
          {
            :path => file,
            :date => Time.parse(file.split('-').last.split('.').first)
          }
        end
        incremental_files.sort_by{|x| x[:date].strftime("%Y%m%d")}.collect do |file|
          bin_log = store.fetch(file)
          run "mysqlbinlog --database=#{db_credentials[:database]} #{bin_log.path}| mysql #{mysql_options}"
        end
      end
    rescue Lockfile::MaxTriesLockError => e
      raise("error, another incremental restore is in progress, exiting.")
    end
  end
  
  # TODO: This method really needs specs
  def clean
    to_keep = []
    filelist = store.list
    files = filelist.reject {|file| file.include?('recent') }.collect do |file|
      {
        :path => file,
        :date => Time.parse(file.split('-').last.split('.').first)
      }
    end
    
    incremental_files = filelist.select{|file|file.include?('mysql-bin')}.collect do |file|
      {
        :path => file,
        :date => Time.parse(file.split('-').last.split('.').first)
      }
    end
    
    # Keep all backups from the past day
    files.select {|x| x[:date] >= 1.day.ago }.each do |backup_for_day|
      to_keep << backup_for_day
    end

    # Keep one backup per day from the last week
    files.select {|x| x[:date] >= 1.week.ago }.group_by {|x| x[:date].strftime("%Y%m%d") }.values.each do |backups_for_last_week|
      to_keep << backups_for_last_week.sort_by{|x| x[:date].strftime("%Y%m%d") }.first
    end

    # Keep one backup per week since forever
    files.group_by {|x| x[:date].strftime("%Y%W") }.values.each do |backups_for_week|
      to_keep << backups_for_week.sort_by{|x| x[:date].strftime("%Y%m%d") }.first
    end
    
    # Keep incremental logs
    incremental_files.each do |recent_incremental_log|
      to_keep << recent_incremental_log
    end
    
    to_destroy = filelist - to_keep.uniq.collect {|x| x[:path] }
    to_destroy.delete_if {|x| x.ends_with?(most_recent_dump_file_name) }
    to_destroy.delete_if {|x| x.ends_with?(most_recent_incremental_dump_file_name) }
    to_destroy.each do |file|
      store.delete(file.split('/').last)
    end
  end
  
  def delete_all_binlogs
    filelist = store.list
    filelist.select{|file|file.include?('mysql-bin')}.collect do |file|
      store.delete(file.split('/').last)
    end
  end

  def statistics
      # From http://mysqlpreacher.com/wordpress/tag/table-size/
    results = ActiveRecord::Base.connection.execute(<<-EOS)
    SELECT
      engine,
      ROUND(data_length/1024/1024,2) total_size_mb,
      ROUND(index_length/1024/1024,2) total_index_size_mb,
      table_rows,
      table_name article_attachment
      FROM information_schema.tables
      WHERE table_schema = '#{db_credentials[:database]}'
      ORDER BY total_size_mb + total_index_size_mb desc;
    EOS
    rows = []
    results.each {|x| rows << x.to_a }
    rows
  end

  private

  def dump_db(mysqldump_path = nil)
    dump_file = Tempfile.new("dump")

    #cmd = "mysqldump --quick --single-transaction --create-options -u#{db_credentials[:user]} --flush-logs --master-data=2 --delete-master-logs"
    #cmd = "mysqldump --quick --single-transaction --create-options #{mysql_options}"
    unless mysqldump_path.nil?
      cmd = "#{mysqldump_path} --quick --single-transaction --create-options #{mysql_options}"
    else
      cmd = "mysqldump --quick --single-transaction --create-options #{mysql_options}"
    end
    cmd += " | gzip > #{dump_file.path}"
    run(cmd)

    dump_file
  end

  def mysql_options
    cmd = ''
    cmd += " -u #{db_credentials[:username]} " unless db_credentials[:username].nil?
    cmd += " -p'#{db_credentials[:password]}'" unless db_credentials[:password].nil?
    cmd += " -h '#{db_credentials[:host]}'"    unless db_credentials[:host].nil?
    cmd += " #{db_credentials[:database]}"
  end
  
  def execute_sql(sql)
    cmd = ''
    cmd += "mysql -e '#{sql}' " 
    cmd += mysql_options
    run(cmd)
  end
  
  def store
    @store ||= S3Store.new
  end

  def most_recent_dump_file_name
    "most-recent-dump-#{db_credentials[:database]}.txt"
  end

  def most_recent_incremental_dump_file_name
    "most-recent-incremental_dump-#{db_credentials[:database]}.txt"
  end
  
  def most_recent_full_dump
    last_full_dump = store.fetch(most_recent_dump_file_name).value
    last_full_dump_date=Time.parse(last_full_dump.split('-').last.split('.').first)
    return last_full_dump_date
  end
  
  def most_recent_incremental_dump
    last_inc_dump = store.fetch(most_recent_incremental_dump_file_name).value
    last_inc_dump_date=Time.parse(last_inc_dump.split('-').last.split('.').first)
    return last_inc_dump_date
  end
  
  def binlog_configured
    unless DB2S3::Config::S3[:incremental_backup]
      return false
    else 
      return DB2S3::Config::S3[:incremental_backup] 
    end
  end
  
  def binlog_path
    if binlog_configured
      return DB2S3::Config::S3[:binlog_path] 
    else
      raise("binlog backup has not been enabled. Please specify binlog_path")
      return false
    end
  end
  
  def temp_dir
    Dir.tmpdir # should be rails tmp? dunno.
  end

  def run(command)
    result = system(command)
    raise("error, process exited with status #{$?.exitstatus}") unless result
  end

  def db_credentials
    ActiveRecord::Base.connection.instance_eval { @config } # Dodgy!
  end

  class S3Store
    def initialize
      @connected = false
    end

    def ensure_connected
      return if @connected
      AWS::S3::Base.establish_connection!(DB2S3::Config::S3.slice(:access_key_id, :secret_access_key).merge(:use_ssl => true))
      AWS::S3::Bucket.create(bucket)
      @connected = true
    end

    def store(file_name, file)
      ensure_connected
      AWS::S3::S3Object.store(file_name, file, bucket)
    end

    def fetch(file_name)
      ensure_connected
      AWS::S3::S3Object.find(file_name, bucket)

      file = Tempfile.new("dump")
      open(file.path, 'w') do |f|
        AWS::S3::S3Object.stream(file_name, bucket) do |chunk|
          f.write chunk
        end
      end
      file
    end
    
    def get(file_name)
      ensure_connected
      AWS::S3::S3Object.find(file_name, bucket).value
    end
      
    def list
      ensure_connected
      AWS::S3::Bucket.find(bucket).objects.collect {|x| x.path }
    end

    def delete(file_name)
      if object = AWS::S3::S3Object.find(file_name, bucket)
        object.delete
      end
    end

    private

    def bucket
      DB2S3::Config::S3[:bucket]
    end
  end

end
