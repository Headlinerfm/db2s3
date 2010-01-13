namespace :db2s3 do
  namespace :backup do
    desc "Save a full back to S3"
    task :full => :environment do
      unless ENV['mysqldump_path'].nil?
        puts "#{ENV['mysqldump_path']}"
        DB2S3.new.full_backup(ENV['mysqldump_path'])
      else
        DB2S3.new.full_backup
      end
      #DB2S3.new.full_backup
    end

    desc "Save an incremental backup to S3"
    task :incremental => :environment do
      DB2S3.new.incremental_backup
    end

    desc "Save an incremental backup to S3"
    task :incremental => :environment do
      DB2S3.new.incremental_backup
    end

    desc "Restore your DB from S3"
    task :restore => :environment do
      DB2S3.new.restore
    end
    
    desc "delete all binlogs"
    task :delete_binlogs => :environment do
      DB2S3.new.delete_binlogs
    end
    
    desc "Keep all backups for the last day, one per day for the last week, and one per week before that. Delete the rest."
    task :clean => :environment do
      DB2S3.new.clean
    end
  end

  desc "Show table sizes for your database"
  task :statistics => :environment do
    rows = DB2S3.new.statistics
    rows.sort_by {|x| -x[3].to_i }
    header = [["Type", "Data MB", "Index", "Rows", "Name"], []]
    puts (header + rows).collect {|x| x.join("\t") }
  end
end
