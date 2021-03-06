#require 'hydra/access_controls'
#require 'hyrax/workflow/activate_object'

class BulkOps::WorkJob < ActiveJob::Base
  attr_accessor :status, :work, :type

  queue_as :ingest

  after_perform do |job|
    
    # update BulkOperationsWorkProxy status
    if  @work.nil? || @work.id.nil?
      update_status "error"
    else
      @work_proxy.work_id = @work.id
      update_status "complete"

      # Attempt to resolve all of the relationships defined in this row   
      @work_proxy.relationships.each do |relationship|
        relationship.resolve!
      end

      # Delete any UploadedFiles. These take up tons of unnecessary disk space.
      @work.file_sets.each do |fileset|
        if uf = Hyrax::UploadedFile.find_by(file: fileset.label)
          begin
            uf.destroy!
          rescue StandardError => e
            Rails.logger.warn("Could not delete uploaded file. #{e.class} - #{e.message}")
          end
        end
      end

      # Remove any edit holds placed on an item
      @work_proxy.lift_hold

      # Check if the parent operation is finished
      # and do any cleanup if so    
      if @work_proxy.operation.present? && @work_proxy.operation.respond_to?(:check_if_finished)
        @work_proxy.operation.check_if_finished 
      end
    end 
  end

  def perform(workClass,user_email,attributes,work_proxy_id,visibility=nil)
    return if status == "complete"
    update_status "starting", "Initializing the job"
    attributes['visibility']= visibility if visibility.present?
    attributes['title'] = ['Untitled'] if attributes['title'].blank?
    @work_proxy = BulkOps::WorkProxy.find(work_proxy_id)
    unless @work_proxy
      report_error("Cannot find work proxy with id: #{work_proxy_id}") 
      return
    end

    return unless (work_action = define_work(workClass))

    user = User.find_by_email(user_email)
    update_status "running", "Started background task at #{DateTime.now.strftime("%d/%m/%Y %H:%M")}"
    ability = Ability.new(user)
    env = Hyrax::Actors::Environment.new(@work, ability, attributes)
    update_status "complete", Hyrax::CurationConcern.actor.send(work_action,env)
  end

  private


  def define_work(workClass="Work")
    if (@work_proxy.present? && @work_proxy.work_id.present? && record_exists?(@work_proxy.work_id))
      begin
        @work = ActiveFedora::Base.find(@work_proxy.work_id)
        return :update
      rescue ActiveFedora::ObjectNotFoundError
        report_error "Could not find work to update in Fedora (though it shows up in Solr). Work id: #{@work_proxy.work_id}"
        return false
      end
    else
      @work = workClass.capitalize.constantize.new
      return :ingest
    end
  end

  def record_exists? id
    begin
      return true if SolrDocument.find(id)
    rescue Blacklight::Exceptions::RecordNotFound
      return false
    end
  end

  def report_error message=nil
    update_status "job_error", message: message
  end

  def type
    #override this, setting as ingest by default
    :create
  end

  def update_status stat, message=false
    @status = stat
    return false unless @work_proxy
    atts = {status: stat}
    atts[:message] = message if message
    @work_proxy.update(atts)
  end

  def define_work(workClass)
    #override this unless you want a simple ingest
    @work = workClass.capitalize.constantize.new
  end

end
