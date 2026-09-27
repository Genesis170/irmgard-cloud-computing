# Connect to RabbitMQ
# Retrieve a job (message)
# Retrieve the image
# Start image processing
# Upload the image
# Acknowledge the message (and thus remove it from the queue)

require 'rubygems'
require 'bundler/setup'

# See https://github.com/ruby-amqp/bunny
# And:
# - https://www.rabbitmq.com/tutorials/tutorial-one-ruby.html
# - https://www.rabbitmq.com/tutorials/tutorial-two-ruby.html
require 'bunny'
require 'fog/aws'
require 'json'
require 'pry'

class ImargardWorkingHard

  def initialize
    # RabbitMQ config
    @rabbit_host = ENV["RABBITMQ_HOST"] || "localhost"
    @rabbit_port     = ENV["RABBITMQ_PORT"] || "5672"
    @rabbit_username = ENV["RABBITMQ_USERNAME"] || "guest"
    @rabbit_password = ENV["RABBITMQ_PASSWORD"] || "guest"
    @rabbit_queue_name = ENV["RABBITMQ_QUEUE"] || "images"

    # Object store config
    @object_store_host = ENV["MINIO_HOST"] || ENV["OBJECT_STORE_HOST"] || "localhost"
    @object_store_port       = ENV["MINIO_PORT"] || "9000"
    @object_store_access_key_id     = ENV["MINIO_ACCESS_KEY"] || ENV['OBJECT_STORE_ACCESS_KEY_ID'] || 'AKIAIOSFODNN7EXAMPLE'
    @object_store_secret_access_key = ENV["MINIO_SECRET_KEY"] || ENV['OBJECT_STORE_SECRET_ACCESS_KEY'] || 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'

    # Provider and Region
    @object_store_provider   = ENV["OBJECT_STORE_PROVIDER"] || 'AWS'
    @object_store_region = ENV['MINIO_REGION'] || 'us-east-1'

    # Bucket-name
    @in_bucket  = ENV["BUCKET_NAME"] || "infiles"
    @out_bucket = ENV["OUT_BUCKET_NAME"] || "outfiles"

    
    # Lokale Dateipfade
    @object_recognition_infile = ENV["INFILE_PATH"] || "/tmp/object_recognition/original-image.jpg"    # TODO done
    @object_recognition_outfile = ENV["OUTFILE_PATH"] || "/tmp/object_recognition/filtered-image.jpg"   # TODO done

    #Typ
    @object_store_content_type = ENV["OBJECT_STORE_CONTENT_TYPE"] || "image/jpeg"


    # RabbitMQ Connection Env
    @rabbit_con = Bunny.new("amqp://#{@rabbit_username}:#{@rabbit_password}@#{@rabbit_host}:#{@rabbit_port}") #TODO done
    @rabbit_con.start

    @rabbit_channel = @rabbit_con.create_channel
    @rabbit_channel.prefetch(1)
    @rabbit_queue = @rabbit_channel.queue(@rabbit_queue_name, durable: true, arguments: { 'x-queue-type' => 'quorum' }) # TODO done

    @obj_store_con = connect_to_object_store
  end

  protected

  #TODO done
  def connect_to_object_store
    # Fog AWS Gem. See: 
    #   https://github.com/fog/fog-aws
    #   https://www.rubydoc.info/github/fog/fog-aws
    # MinIO emulates the AWS API > use the AWS adapter
    connection = Fog::Storage.new({
      provider:              @object_store_provider,                               # TODO done
      aws_access_key_id:     @object_store_access_key_id,
      aws_secret_access_key: @object_store_secret_access_key,
      region:                @object_store_region,                     # optional, defaults to 'us-east-1',
                                                                  # Please mention other regions if you have changed
                                                                  # minio configuration
      host:                  @object_store_host,                  # Provide your host name here, otherwise fog-aws defaults to
                                                                  # s3.amazonaws.com
      endpoint:              "http://#{@object_store_host}:#{@object_store_port}", # TODO done
      path_style:            true,                                # Required
  })

    # Create Outfiles-Bucket
    ensure_bucket_exists(connection, @out_bucket)
    return connection
  end

  # Check if bucket exists 
  def ensure_bucket_exists(connection, bucket_name)
    unless connection.directories.get(bucket_name)
      puts "\t\tBucket '#{bucket_name}' does not exist, creating it..."
      connection.directories.create(key: bucket_name)
      puts "\t\tDone."
    end
  end

  def retrieve_object_recognition_infile_from_object_store(filepath)    
    puts "\t\tStarting to retrieve object #{filepath} and storing it to #{@object_recognition_infile}..."
    directory = @obj_store_con.directories.get(@in_bucket) # TODO done
    remote_file = directory.files.get(filepath)

    # Create local file from the remote file    
    File.open(@object_recognition_infile, "w") do |local_file|

      # Only recommendable for small objects
      local_file.write(remote_file.body)
    end  
    puts "\t\tDone."
  end

  def upload_object_recognition_outfile_to_object_store(object_name)    
    puts "\t\tStarting to upload object #{object_name} from local file #{@object_recognition_outfile}"
    @obj_store_con.put_object(
        @out_bucket, # TODO done
        object_name,

        # Only recommendable for small objects
        File.read(@object_recognition_outfile),
        content_type: @object_store_content_type # TODO done
      )
  end

  def cleanup
    puts "\t\tRemoving local files #{@object_recognition_infile} and #{@object_recognition_outfile}"

    # Delete the old infile. This avoids accidentally processing a file twice.
    FileUtils.rm @object_recognition_infile
    FileUtils.rm @object_recognition_outfile

    puts "\t\tDone."
  end

  def execute_object_recognition
    cmd = 'python3 yolo_opencv.py --image /tmp/object_recognition/original-image.jpg --config yolov3.cfg --weights yolov3.weights --classes yolov3.txt'
    puts "\t\tExecuting object recognition with CMD: #{cmd}"
    system(cmd)
    puts "\t\tDone."
  end

  public

  def work!
    puts "Imrgard started working hard ..."
    # Manual acknowledgement gives us control over when the processing of the image was successful
    # Unsuccessful processing should leave the message in the queue for other workers to pick up.
    @rabbit_queue.subscribe(manual_ack: true, block: true) do |delivery_info, properties, body|
      puts "\tReceived message: #{body}.\nStarting to process..."

      # Parse JSON message
      msg = JSON.parse(body)
      object_name = msg["name"]

      # Store as @object_recognition_infile
      retrieve_object_recognition_infile_from_object_store(object_name)

      execute_object_recognition
      
      upload_object_recognition_outfile_to_object_store(object_name)

      cleanup

      @rabbit_channel.ack(delivery_info.delivery_tag)
      puts "\tDone processing."
    end
    puts "Irmgard worked hard. Now going to rest a bit ..."
  end
end




ImargardWorkingHard.new.work!