require 'ancestry'
require 'ostruct'
require 'cgi'
require 'uri'

class VmOrTemplate < ApplicationRecord
  include NewWithTypeStiMixin
  include RetirementMixin
  include ScanningMixin
  include SupportsFeatureMixin
  include SupportsAttribute
  include EmsRefreshMixin

  self.table_name = 'vms'
  has_ancestry

  include Operations
  include RetirementManagement
  include RightSizing
  include Scanning
  include Snapshotting

  attr_accessor :surrogate_host

  @surrogate_host = nil

  include ProviderObjectMixin
  include ComplianceMixin
  include OwnershipMixin
  include CustomAttributeMixin

  include EventMixin
  include ProcessTasksMixin
  include TenancyMixin
  include ManageIQ::Providers::Inflector::Methods

  VENDOR_TYPES = {
    # DB            Displayed
    "azure"           => "Azure",
    "azure_stack"     => "AzureStack",
    "vmware"          => "VMware",
    "microsoft"       => "Microsoft",
    "xen"             => "XenSource",
    "parallels"       => "Parallels",
    "amazon"          => "Amazon",
    "redhat"          => "Red Hat",
    "ovirt"           => "oVirt",
    "openstack"       => "OpenStack",
    "openshift_infra" => "OpenShift Virtualization",
    "oracle"          => "Oracle",
    "google"          => "Google",
    "kubevirt"        => "KubeVirt",
    "nutanix"         => "Nutanix",
    "ibm_cloud"       => "IBM Cloud",
    "ibm_power_vs"    => "IBM Power Systems Virtual Server",
    "ibm_power_vc"    => "IBM PowerVC",
    "ibm_power_hmc"   => "IBM Power HMC",
    "ibm_z_vm"        => "IBM Z/VM",
    "unknown"         => "Unknown"
  }

  POWER_OPS = %w[start stop suspend reset shutdown_guest standby_guest reboot_guest]
  REMOTE_REGION_TASKS = POWER_OPS + %w[retire_now]

  validates_presence_of     :name, :location
  validates                 :vendor, :inclusion => {:in => VENDOR_TYPES.keys}

  has_one                   :operating_system, :dependent => :destroy
  has_one                   :openscap_result, :as => :resource, :dependent => :destroy
  has_one                   :hardware, :dependent => :destroy
  has_one                   :miq_provision, :dependent => :nullify, :as => :destination
  has_one                   :miq_provision_template, :through => "miq_provision", :source => "source", :source_type => "VmOrTemplate"
  has_one                   :miq_server, :foreign_key => :vm_id, :inverse_of => :vm

  belongs_to                :host
  belongs_to                :ems_cluster
  belongs_to                :cloud_tenant
  belongs_to                :flavor

  belongs_to                :placement_group

  belongs_to                :storage
  belongs_to                :storage_profile
  belongs_to                :ext_management_system, :foreign_key => "ems_id", :inverse_of => :vms_and_templates
  belongs_to                :resource_group
  belongs_to                :tenant

  # Accounts - Users and Groups
  has_many                  :accounts, :dependent => :destroy
  has_many                  :users, -> { where(:accttype => 'user') }, :class_name => "Account"
  has_many                  :groups, -> { where(:accttype => 'group') }, :class_name => "Account"
  has_many                  :disks, :through => :hardware
  has_many                  :networks, :through => :hardware
  has_many                  :nics, :through => :hardware
  has_many                  :miq_provisions_from_template, :class_name => "MiqProvision", :as => :source, :dependent => :nullify
  has_many                  :miq_provision_vms, :through => :miq_provisions_from_template, :source => :destination, :source_type => "VmOrTemplate"
  has_many                  :miq_provision_requests, :as => :source
  has_many                  :guest_applications, :dependent => :destroy
  has_many                  :patches, :dependent => :destroy
  # System Services - Win32_Services, Kernel drivers, Filesystem drivers
  has_many                  :system_services, :dependent => :destroy
  has_many                  :win32_services, -> { where("typename = 'win32_service'") }, :class_name => "SystemService"
  has_many                  :kernel_drivers, -> { where("typename = 'kernel' OR typename = 'misc'") }, :class_name => "SystemService"
  has_many                  :filesystem_drivers, -> { where("typename = 'filesystem'") },  :class_name => "SystemService"
  has_many                  :linux_initprocesses, -> { where("typename = 'linux_initprocess' OR typename = 'linux_systemd'") }, :class_name => "SystemService"

  has_many                  :filesystems, :as => :resource, :dependent => :destroy
  has_many                  :directories, -> { where("rsc_type = 'dir'") }, :as => :resource, :class_name => "Filesystem"
  has_many                  :files, -> { where("rsc_type = 'file'") },       :as => :resource, :class_name => "Filesystem"

  has_many                  :scan_histories,    :dependent => :destroy
  has_many                  :lifecycle_events,  :class_name => "LifecycleEvent"
  has_many                  :advanced_settings, :as => :resource, :dependent => :destroy

  # Scan Items
  has_many                  :registry_items, :dependent => :destroy

  has_many                  :metrics,        :as => :resource  # Destroy will be handled by purger
  has_many                  :metric_rollups, :as => :resource  # Destroy will be handled by purger
  has_many                  :vim_performance_states, :as => :resource  # Destroy will be handled by purger

  has_many                  :storage_files, :dependent => :destroy
  has_many                  :storage_files_files, -> { where("rsc_type = 'file'") }, :class_name => "StorageFile"

  # EMS Events
  has_many                  :ems_events, ->(vmt) { unscope(:where => :vm_or_template_id).where(["vm_or_template_id = ? OR dest_vm_or_template_id = ?", vmt.id, vmt.id]).order(:timestamp) },
                            :class_name => "EmsEvent", :inverse_of => :vm_or_template

  has_many                  :ems_events_src,  :class_name => "EmsEvent"
  has_many                  :ems_events_dest, :class_name => "EmsEvent", :foreign_key => :dest_vm_or_template_id

  has_many                  :policy_events, ->(vm) { where(["target_id = ? AND target_class = 'VmOrTemplate'", vm.id]).order(:timestamp) }, :foreign_key => "target_id"

  has_many                  :miq_events, :as => :target, :dependent => :destroy

  has_many                  :miq_alert_statuses, :dependent => :destroy, :as => :resource

  has_many                  :service_resources, :as => :resource
  has_many                  :direct_services, :through => :service_resources, :source => :service
  has_many                  :connected_shares, -> { where(:resource_type => "VmOrTemplate") }, :foreign_key => :resource_id, :class_name => "Share"
  has_many                  :labels, -> { where(:section => "labels") }, # rubocop:disable Rails/HasManyOrHasOneDependent
                            :class_name => "CustomAttribute",
                            :as         => :resource,
                            :inverse_of => :resource
  has_many                  :ems_custom_attributes, -> { where(:source => 'VC') }, # rubocop:disable Rails/HasManyOrHasOneDependent
                            :class_name => "CustomAttribute",
                            :as         => :resource,
                            :inverse_of => :resource
  has_many                  :counterparts, :as => :counterpart, :class_name => "ConfiguredSystem", :dependent => :nullify

  has_and_belongs_to_many   :storages, :join_table => 'storages_vms_and_templates'

  acts_as_miq_taggable

  virtual_column :is_evm_appliance,                     :type => :boolean,    :uses => :miq_server
  virtual_column :os_image_name,                        :type => :string,     :uses => [:operating_system, :hardware]
  virtual_column :platform,                             :type => :string,     :uses => [:operating_system, :hardware]
  virtual_column :product_name,                         :type => :string,     :uses => [:operating_system]
  virtual_column :vendor_display,                       :type => :string
  virtual_column :v_owning_cluster,                     :type => :string,     :uses => :ems_cluster
  virtual_column :v_owning_resource_pool,               :type => :string,     :uses => :all_relationships
  virtual_column :v_owning_datacenter,                  :type => :string,     :uses => {:ems_cluster => :all_relationships}
  virtual_column :v_owning_folder,                      :type => :string,     :uses => {:ems_cluster => :all_relationships}
  virtual_column :v_owning_folder_path,                 :type => :string,     :uses => {:ems_cluster => :all_relationships}
  virtual_column :v_owning_blue_folder,                 :type => :string,     :uses => :all_relationships
  virtual_column :v_owning_blue_folder_path,            :type => :string,     :uses => :all_relationships
  virtual_column :v_datastore_path,                     :type => :string,     :uses => :storage
  virtual_column :v_parent_blue_folder_display_path,    :type => :string,     :uses => :all_relationships
  virtual_column :thin_provisioned,                     :type => :boolean,    :uses => {:hardware => :disks}
  virtual_column :used_storage,                         :type => :integer,    :uses => [:used_disk_storage, :mem_cpu]
  virtual_column :used_storage_by_state,                :type => :integer,    :uses => :used_storage
  virtual_column :uncommitted_storage,                  :type => :integer,    :uses => [:provisioned_storage, :used_storage_by_state]
  virtual_column :ipaddresses,                          :type => :string_set, :uses => {:hardware => :ipaddresses}
  virtual_column :hostnames,                            :type => :string_set, :uses => {:hardware => :hostnames}
  virtual_column :mac_addresses,                        :type => :string_set, :uses => {:hardware => :mac_addresses}
  virtual_column :memory_exceeds_current_host_headroom, :type => :string,     :uses => [:mem_cpu, {:host => [:hardware, :ext_management_system]}]
  virtual_column :has_rdm_disk,                         :type => :boolean,    :uses => {:hardware => :disks}
  virtual_column :disks_aligned,                        :type => :string,     :uses => {:hardware => {:hard_disks => :partitions_aligned}}

  virtual_has_many   :processes,              :class_name => "OsProcess",    :uses => {:operating_system => :processes}
  virtual_has_many   :event_logs,                                            :uses => {:operating_system => :event_logs}
  virtual_has_many   :lans,                                                  :uses => {:hardware => {:nics => :lan}}
  virtual_has_many   :child_resources,        :class_name => "VmOrTemplate"

  virtual_belongs_to :parent_resource_pool,   :class_name => "ResourcePool", :uses => :all_relationships

  virtual_has_one   :direct_service,       :class_name => 'Service'
  virtual_has_one   :service,              :class_name => 'Service'
  virtual_has_one   :parent_resource,      :class_name => "VmOrTemplate"

  virtual_delegate :name, :to => :host, :prefix => true, :allow_nil => true, :type => :string
  virtual_delegate :name, :to => :storage, :prefix => true, :allow_nil => true, :type => :string
  virtual_delegate :name, :to => :ems_cluster, :prefix => true, :allow_nil => true, :type => :string
  virtual_delegate :vmm_product, :to => :host, :prefix => :v_host, :allow_nil => true, :type => :string
  virtual_delegate :v_pct_free_disk_space, :v_pct_used_disk_space, :to => :hardware, :allow_nil => true, :type => :float
  virtual_delegate :num_cpu, :to => "hardware.cpu_sockets", :allow_nil => true, :default => 0, :type => :integer
  virtual_delegate :cpu_total_cores, :cpu_cores_per_socket, :to => :hardware, :allow_nil => true, :default => 0, :type => :integer
  virtual_delegate :annotation, :to => :hardware, :prefix => "v", :allow_nil => true, :type => :string
  virtual_delegate :ram_size_in_bytes,                  :to => :hardware, :allow_nil => true, :default => 0, :type => :integer
  virtual_delegate :mem_cpu,                            :to => "hardware.memory_mb", :allow_nil => true, :default => 0, :type => :integer
  virtual_delegate :ram_size,                           :to => "hardware.memory_mb", :allow_nil => true, :default => 0, :type => :integer

  delegate :connect_lans, :disconnect_lans, :to => :hardware, :allow_nil => true
  delegate :queue_name_for_ems_operations, :to => :ext_management_system, :allow_nil => true

  supports_attribute :feature => :reconfigure_disks
  supports_attribute :feature => :reconfigure_disksize
  supports_attribute :feature => :reconfigure_cdroms
  supports_attribute :feature => :reconfigure_network_adapters

  after_save :save_genealogy_information

  scope :active,       ->       { where.not(:ems_id => nil) }
  scope :with_type,    ->(type) { where(:type => type) }
  scope :archived,     ->       { where(:ems_id => nil, :storage_id => nil) }
  scope :orphaned,     ->       { where(:ems_id => nil).where.not(:storage_id => nil) }
  scope :retired,      ->       { where(:retired => true) }
  scope :not_active,   ->       { where(:ems_id => nil) }
  scope :not_archived, ->       { where.not(:ems_id => nil).or(where.not(:storage_id => nil)) }
  scope :not_orphaned, ->       { where.not(:ems_id => nil).or(where(:storage_id => nil)) }
  scope :not_retired,  ->       { where(:retired => false).or(where(:retired => nil)) }

  scope :from_cloud_managers, -> { where(:ext_management_system => ManageIQ::Providers::CloudManager.all) }
  scope :from_infra_managers, -> { where(:ext_management_system => ManageIQ::Providers::InfraManager.all) }

  def from_cloud_manager?
    ext_management_system&.kind_of?(ManageIQ::Providers::CloudManager)
  end

  def from_infra_manager?
    ext_management_system&.kind_of?(ManageIQ::Providers::InfraManager)
  end

  # The SQL form of `#registered?`, with its inverse as well.
  # TODO: Vmware Specific (copied (old) TODO from #registered?)
  scope :registered, (lambda do
    where(arel_table[:template].eq(false).or(arel_table[:ems_id].not_eq(nil)).and(arel_table[:host_id].not_eq(nil)))
  end)
  scope :unregistered, (lambda do
    where(arel_table[:template].eq(true).and(arel_table[:ems_id].eq(nil)).or(arel_table[:host_id].eq(nil)))
  end)

  alias_method :datastores, :storages    # Used by web-services to return datastores as the property name

  alias_method :parent_cluster, :ems_cluster
  alias_method :owning_cluster, :ems_cluster

  # Add virtual columns/methods for specific things derived from advanced_settings
  REQUIRED_ADVANCED_SETTINGS = {
    'vmi.present'         => [:paravirtualization,   :boolean],
    'vmsafe.enable'       => [:vmsafe_enable,        :boolean],
    'vmsafe.agentAddress' => [:vmsafe_agent_address, :string],
    'vmsafe.agentPort'    => [:vmsafe_agent_port,    :integer],
    'vmsafe.failOpen'     => [:vmsafe_fail_open,     :boolean],
    'vmsafe.immutableVM'  => [:vmsafe_immutable_vm,  :boolean],
    'vmsafe.timeoutMS'    => [:vmsafe_timeout_ms,    :integer],
    'entitled_processors' => [:entitled_processors,  :float],
    'processor_type'      => [:processor_share_type, :string],
    'pin_policy'          => [:processor_pin_policy, :string],
    'software_licenses'   => [:software_licenses,    :string],
  }
  REQUIRED_ADVANCED_SETTINGS.each do |k, (m, t)|
    define_method(m) do
      as = advanced_settings.detect { |setting| setting.name == k }
      return nil if as.nil? || as.value.nil?

      case t
             when :boolean then ActiveRecord::Type::Boolean.new.cast(as.value)
             when :integer then as.value.to_i
             when :float then as.value.to_f
             else as.value.to_s
             end
    end

    virtual_column m, :type => t, :uses => :advanced_settings
  end

  # Add virtual columns/methods for details about each disk
  (1..9).each do |i|
    disk_methods = [
      ['disk_type',                   :string],
      ['mode',                        :string],
      ['size',                        :integer],
      ['size_on_disk',                :integer],
      ['used_percent_of_provisioned', :float],
      ['partitions_aligned',          :string]
    ]

    disk_methods.each do |k, t|
      m  = "disk_#{i}_#{k}".to_sym

      define_method(m) do
        return nil if hardware.nil?
        return nil if hardware.hard_disks.length < i

        hardware.hard_disks[i - 1].send(k)
      end

      virtual_column m, :type => t, :uses => {:hardware => :hard_disks}
    end
  end

  # Add virtual columns/methods for accessing individual folders in a path
  (1..9).each do |i|
    m = "parent_blue_folder_#{i}_name".to_sym

    define_method(m) do
      f = parent_blue_folders(:exclude_root_folder => true, :exclude_non_display_folders => true)[i - 1]
      f.nil? ? "" : f.name
    end

    virtual_column m, :type => :string, :uses => :all_relationships
  end

  include RelationshipMixin
  self.default_relationship_type = "genealogy"
  self.skip_relationships += ["genealogy"]

  include MiqPolicyMixin
  include AlertMixin
  include DriftStateMixin
  include UuidMixin
  include Metric::CiMixin

  include FilterableMixin
  include StorageMixin

  def self.manager_class
    if module_parent == Object
      ExtManagementSystem
    else
      module_parent
    end
  end

  def self.model_suffix
    manager_class.short_token
  end

  def to_s
    name
  end

  def is_evm_appliance?
    !!miq_server
  end
  alias_method :is_evm_appliance,  :is_evm_appliance?

  # Determines if the VM is on an EMS or Host
  def registered?
    # TODO: Vmware specific
    return false if template? && ems_id.nil?

    host_id.present?
  end

  # TODO: Vmware specific, and is this even being used anywhere?
  def connected_to_ems?
    connection_state == 'connected' || connection_state.nil?
  end

  def terminated?
    current_state == 'terminated'
  end

  def makesmart(_options = {})
    self.smart = true
    save
  end

  def run_command_via_parent(verb, options = {})
    unless ext_management_system
      raise _("VM/Template <%{name}> with Id: <%{id}> is not associated with a provider.") % {:name => name, :id => id}
    end
    unless ext_management_system.authentication_status_ok?
      raise _("VM/Template <%{name}> with Id: <%{id}>: Provider authentication failed.") % {:name => name, :id => id}
    end

    # TODO: Need to break this logic out into a method that can look at the verb and the vm and decide the best way to invoke it - Virtual Center WS, ESX WS, Storage Proxy.
    _log.info("Invoking [#{verb}] through EMS: [#{ext_management_system.name}]")
    options = {:user_event => "Console Request Action [#{verb}], VM [#{name}]"}.merge(options)
    ext_management_system.send(verb, self, options)
  end

  def run_command_via_task(task_options, queue_options)
    MiqTask.generic_action_with_callback(task_options, command_queue_options(queue_options))
  end

  def run_command_via_queue(method_name, queue_options = {})
    queue_options[:method_name] = method_name
    MiqQueue.put(command_queue_options(queue_options))
  end

  def make_retire_request(requester_id)
    self.class.make_retire_request(id, User.find(requester_id))
  end

  # keep the same method signature as others in retirement mixin
  def self.make_retire_request(*src_ids, requester, initiated_by: 'user')
    vms = where(:id => src_ids)

    missing_ids = src_ids - vms.pluck(:id)
    _log.error("Retirement of [Vm] IDs: [#{missing_ids.join(', ')}] skipped - target(s) does not exist") if missing_ids.present?

    vms.each do |target|
      target.check_policy_prevent('request_vm_retire', "retire_request_after_policy_check", requester.userid, :initiated_by => initiated_by)
    end
  end

  def retire_request_after_policy_check(userid, initiated_by: 'user')
    options = {:src_ids => [id], :__initiated_by__ => initiated_by, :__request_type__ => VmRetireRequest.request_types.first}
    requester = User.find_by(:userid => userid)
    self.class.set_retirement_requester(options[:src_ids], requester)
    VmRetireRequest.make_request(nil, options, requester)
  end

  # policy_event: the event sent to automate for policy resolution
  # cb_method:    the MiqQueue callback method along with the parameters that is called
  #               when automate process is done and the event is not prevented to proceed by policy
  def check_policy_prevent(policy_event, *cb_method)
    enforce_policy(policy_event, {}, {:miq_callback => prevent_callback_settings(*cb_method)}) unless policy_event.nil?
  end

  def enforce_policy(event, inputs = {}, options = {})
    return {"result" => true, :details => []} if event.to_s == "rsop" && host.nil?
    raise _("vm does not belong to any host") if host.nil? && ext_management_system.nil?

    inputs[:vm]                    = self
    inputs[:host]                  = host                  unless host.nil?
    inputs[:ext_management_system] = ext_management_system unless ext_management_system.nil?
    MiqEvent.raise_evm_event(self, event, inputs, options)
  end

  # override
  def self.validate_task(task, vm, options)
    return false unless super
    return false if options[:task] == "destroy" || options[:task] == "check_compliance_queue"
    return false if vm.has_required_host?

    # VM has no host or storage affiliation
    if vm.storage.nil?
      task.error("#{vm.name}: There is no owning Host or Datastore for this VM, " \
                 "'#{options[:task]}' is not allowed")
      return false
    end

    # VM belongs to a storage/repository location
    # TODO: The following never gets run since the invoke tasks invokes it as a job, and only tasks get to this point ?
    unless %w[scan sync].include?(options[:task])
      task.error("#{vm.name}: There is no owning Host for this VM, '#{options[:task]}' is not allowed")
      return false
    end
    spid = ::Settings.repository_scanning.defaultsmartproxy
    if spid.nil?                          # No repo scanning SmartProxy configured
      task.error("#{vm.name}: No Default Repository SmartProxy is configured, contact your EVM administrator")
      return false
    elsif MiqProxy.exists?(spid) == false
      task.error("#{vm.name}: The Default Repository SmartProxy no longer exists, contact your EVM Administrator")
      return false
    end
    if MiqProxy.find(spid).state != "on"                     # Repo scanning host iagent s not running
      task.error("#{vm.name}: The Default Repository SmartProxy, '#{sp.name}', is not running. " \
                 "'#{options[:task]}' not attempted")
      return false
    end
    true
  end
  private_class_method :validate_task

  # override
  def self.task_invoked_by(options)
    %w[scan sync].include?(options[:task]) ? :job : super
  end
  private_class_method :task_invoked_by

  # override
  def self.task_arguments(options)
    case options[:task]
    when "scan", "sync"
      [options[:userid]]
    when "remove_snapshot", "revert_to_snapshot"
      [options[:snap_selected]]
    when "create_snapshot"
      [options[:name], options[:description], options[:memory]]
    else
      super
    end
  end
  private_class_method :task_arguments

  def powerops_callback(task_id, status, msg, result, _queue_item)
    task = MiqTask.find_by(:id => task_id)
    task.queue_callback("Finished", status, msg, result) if task
  end

  # override
  def self.invoke_task_local(task, vm, options, args)
    user = User.current_user
    cb = nil
    if task
      cb =
        if POWER_OPS.include?(options[:task])
          {
            :class_name  => vm.class.base_class.name,
            :instance_id => vm.id,
            :method_name => :powerops_callback,
            :args        => [task.id]
          }
        else
          {
            :class_name  => task.class.to_s,
            :instance_id => task.id,
            :method_name => :queue_callback,
            :args        => ["Finished"]
          }
        end
    end

    q_hash =
      if options[:task] == "destroy"
        {
          :class_name   => base_class.name,
          :instance_id  => vm.id,
          :method_name  => options[:task],
          :args         => args,
          :miq_task_id  => task&.id,
          :miq_callback => cb,
        }
      else
        {
          :service      => options[:invoke_by] == :job ? "smartstate" : "ems_operations",
          :affinity     => vm.ext_management_system,
          :class_name   => base_class.name,
          :instance_id  => vm.id,
          :method_name  => options[:task],
          :args         => args,
          :miq_task_id  => task&.id,
          :miq_callback => cb,
        }
      end
    q_hash.merge!(:user_id => user.id, :group_id => user.current_group.id, :tenant_id => user.current_tenant.id) if user
    MiqQueue.submit_job(q_hash)
  end

  def self.action_for_task(task)
    case task
    when "retire_now"
      "retire"
    else
      task
    end
  end

  def scan_data_current?
    !(last_scan_on.nil? || last_scan_on > last_sync_on)
  end

  def genealogy_parent
    with_relationship_type("genealogy") { parent }
  end

  def genealogy_parent=(parent)
    with_relationship_type('genealogy') do
      if use_ancestry?
        self.parent = parent
      else
        @genealogy_parent_object = parent
      end
    end
  end

  # save_genealogy_information is only necessary for relationships using genealogy
  # when using ancestry, the relationship will be saved after the fact
  # when not using ancestry, the relationship is saved on assignment, necessitating the prior save of the vm/template record
  # this variable is used to delay that assignment
  def save_genealogy_information
    if defined?(@genealogy_parent_object) && @genealogy_parent_object
      with_relationship_type('genealogy') { self.parent = @genealogy_parent_object }
    end
  end

  def os_image_name
    name = OperatingSystem.image_name(self)
    if name == 'unknown'
      parent = genealogy_parent
      name = OperatingSystem.image_name(parent) unless parent.nil?
    end
    name
  end

  def platform
    name = OperatingSystem.platform(self)
    if name == 'unknown'
      parent = genealogy_parent
      name = OperatingSystem.platform(parent) unless parent.nil?
    end
    name
  end

  def product_name
    name   = try(:operating_system).try(:product_name)
    name ||= genealogy_parent.try(:operating_system).try(:product_name)
    name ||= ""
    name
  end

  def service_pack
    name   = try(:operating_system).try(:service_pack)
    name ||= genealogy_parent.try(:operating_system).try(:service_pack)
    name ||= ""
    name
  end

  def vendor_display
    VENDOR_TYPES[vendor]
  end

  #
  # Path/location methods
  #

  # TODO: Vmware specific URI methods?  Next 3 methods
  def self.location2uri(location, scheme = "file")
    pat = %r{^(file|http|miq)://([^/]*)/(.+)$}
    unless pat&.match?(location)
      # location = scheme<<"://"<<self.myhost.ipaddress<<":1139/"<<location
      location = scheme << ":///" << location
    end
    location
  end

  def save_scan_history(datahash)
    result = scan_histories.build(
      :status      => datahash['status'],
      :status_code => datahash['status_code'].to_i,
      :message     => datahash['message'],
      :started_on  => Time.parse(datahash['start_time']),
      :finished_on => Time.parse(datahash['end_time']),
      :task_id     => datahash['taskid']
    )
    self.last_scan_on = Time.parse(datahash['start_time'])
    save
    result
  end

  def self.repository_parse_path(path)
    path.tr!("\\", "/")
    # it's empty string for local type
    storage_name = ""
    # NAS
    relative_path = if path.starts_with?("//")
                      raise _("path, '%{path}', is malformed") % {:path => path} unless %r{^//[^/].*/.+$}.match?(path)

                      # path is a UNC
                      storage_name = path.split("/")[0..3].join("/")
                      path.split("/")[4..path.length].join("/") if path.length > 4
                    # VMFS
                    elsif path.starts_with?("[")
                      raise _("path, '%{path}', is malformed") % {:path => path} unless /^\[[^\]].+\].*$/.match?(path)

                      # path is a VMWare storage name
                      /^\[(.*)\](.*)$/ =~ path
                      storage_name = $1
                      temp_path = $2.strip
                      # Some esx servers add a leading "/".
                      # This needs to be stripped off to allow matching on location
                      temp_path.sub(/^\//, '')
                    # local
                    else
                      raise _("path, '%{path}', is malformed") % {:path => path}
                    end
    return storage_name, (relative_path.empty? ? "/" : relative_path)
  end
  #
  # Relationship methods
  #

  def disconnect_inv
    disconnect_storage
    disconnect_ems

    classify_with_parent_folder_path(false)

    with_relationship_type('ems_metadata') do
      remove_all_parents(:of_type => ['EmsFolder', 'ResourcePool'])
    end

    disconnect_host
    disconnect_stack if respond_to?(:orchestration_stack)
  end

  def disconnect_stack(stack = nil)
    return unless orchestration_stack
    return if stack && stack != orchestration_stack

    log_text = " from stack [#{orchestration_stack.name}] id [#{orchestration_stack.id}]"
    _log.info("Disconnecting Vm [#{name}] id [#{id}]#{log_text}")

    self.orchestration_stack = nil
    save
  end

  def connect_ems(e)
    unless ext_management_system == e
      _log.debug("Connecting Vm [#{name}] id [#{id}] to EMS [#{e.name}] id [#{e.id}]")
      self.ext_management_system = e
      save
    end
  end

  def disconnect_ems(e = nil)
    if e.nil? || ext_management_system == e
      log_text = " from EMS [#{ext_management_system.name}] id [#{ext_management_system.id}]" unless ext_management_system.nil?
      _log.info("Disconnecting Vm [#{name}] id [#{id}]#{log_text}")

      self.ext_management_system = nil
      self.ems_cluster = nil
      self.raw_power_state = "unknown"
      save
    end
  end

  def connect_host(h)
    unless host == h
      _log.debug("Connecting Vm [#{name}] id [#{id}] to Host [#{h.name}] id [#{h.id}]")
      self.host = h
      save

      # Also connect any nics to their lans
      connect_lans(h.lans)
    end
  end

  def disconnect_host(h = nil)
    if h.nil? || host == h
      log_text = " from Host [#{host.name}] id [#{host.id}]" unless host.nil?
      _log.info("Disconnecting Vm [#{name}] id [#{id}]#{log_text}")

      self.host = nil
      save

      # Also disconnect any nics from their lans
      disconnect_lans
    end
  end

  def connect_storage(s)
    unless storage == s
      _log.debug("Connecting Vm [#{name}] id [#{id}] to Datastore [#{s.name}] id [#{s.id}]")
      self.storage = s
      save
    end
  end

  def disconnect_storage(s = nil)
    if s.nil? || storage == s || storages.include?(s)
      stores = s.nil? ? ([storage] + storages).compact.uniq : [s]
      log_text = stores.collect { |x| "Datastore [#{x.name}] id [#{x.id}]" }.join(", ")
      _log.info("Disconnecting Vm [#{name}] id [#{id}] from #{log_text}")

      if s.nil?
        self.storage = nil
        self.storages = []
      else
        self.storage = nil if storage == s
        storages.delete(s)
      end

      save
    end
  end

  # Parent rp, folder and dc methods
  # TODO: Replace all with ancestors lookup once multiple parents is sorted out
  def parent_resource_pool
    with_relationship_type('ems_metadata') do
      parent(:of_type => "ResourcePool")
    end
  end
  alias_method :owning_resource_pool, :parent_resource_pool

  def parent_blue_folder
    with_relationship_type('ems_metadata') do
      parent(:of_type => "EmsFolder")
    end
  end
  alias_method :owning_blue_folder, :parent_blue_folder

  def parent_blue_folders(*args)
    f = parent_blue_folder
    f.nil? ? [] : f.folder_path_objs(*args)
  end

  def under_blue_folder?(folder)
    return false unless folder.kind_of?(EmsFolder)

    parent_blue_folders.any? { |f| f == folder }
  end

  def parent_blue_folder_path(*args)
    f = parent_blue_folder
    f.nil? ? "" : f.folder_path(*args)
  end
  alias_method :owning_blue_folder_path, :parent_blue_folder_path

  def parent_folder
    ems_cluster.try(:parent_folder)
  end
  alias_method :owning_folder, :parent_folder
  alias_method :parent_yellow_folder, :parent_folder

  def parent_folders(*args)
    f = parent_folder
    f.nil? ? [] : f.folder_path_objs(*args)
  end
  alias_method :parent_yellow_folders, :parent_folders

  def parent_folder_path(*args)
    f = parent_folder
    f.nil? ? "" : f.folder_path(*args)
  end
  alias_method :owning_folder_path, :parent_folder_path
  alias_method :parent_yellow_folder_path, :parent_folder_path

  def parent_datacenter
    ems_cluster.try(:parent_datacenter)
  end
  alias_method :owning_datacenter, :parent_datacenter

  def parent_blue_folder_display_path
    parent_blue_folder_path(:exclude_non_display_folders => true)
  end
  alias_method :v_parent_blue_folder_display_path, :parent_blue_folder_display_path

  def lans
    !hardware.nil? ? hardware.nics.collect(&:lan).compact : []
  end

  # Create a hash of this Vm's EMS and Host and their credentials
  def ems_host_list
    params = {}
    [ext_management_system, "ems", host, "host"].each_slice(2) do |ems, type|
      if ems
        params[type] = {
          :hostname   => ems.hostname,
          :ipaddress  => ems.ipaddress,
          :username   => ems.authentication_userid,
          :password   => ems.authentication_password_encrypted,
          :class_name => ems.class.name
        }
        params[type][:port] = ems.port if ems.respond_to?(:port) && ems.port.present?
      end
    end
    params
  end

  def reconnect_events
    events = EmsEvent.where("ems_id = ? AND ((vm_ems_ref = ? AND vm_or_template_id IS NULL) OR (dest_vm_ems_ref = ? AND dest_vm_or_template_id IS NULL))", ext_management_system.id, ems_ref, ems_ref)
    events.each do |e|
      do_save = false

      src_vm = e.src_vm_or_template
      if src_vm.nil? && e.vm_ems_ref == ems_ref
        src_vm = self
        e.vm_or_template_id = src_vm.id
        e.vm_name = src_vm.name
        do_save = true
      end

      dest_vm = e.dest_vm_or_template
      if dest_vm.nil? && e.dest_vm_ems_ref == ems_ref
        dest_vm = self
        e.dest_vm_or_template_id = dest_vm.id
        do_save = true
      end

      e.save if do_save

      # Hook up genealogy after a Clone Task
      src_vm.add_genealogy_child(dest_vm) if src_vm && dest_vm && e.event_type == EmsEvent::CLONE_TASK_COMPLETE
    end

    true
  end

  def add_genealogy_child(child)
    with_relationship_type('genealogy') do
      set_child(child)
    end
  end

  def myhost
    return @surrogate_host if @surrogate_host
    return host unless host.nil?

    self.class.proxy_host_for_repository_scans
  end

  def self.scan_via_ems?
    !::Settings.coresident_miqproxy.scan_via_host
  end

  delegate :scan_via_ems?, :to => :class

  # Cache the proxy host for repository scans because the JobProxyDispatch calls this for each Vm scan job in a loop
  cache_with_timeout(:proxy_host_for_repository_scans, 30.seconds) do
    defaultsmartproxy = ::Settings.repository_scanning.defaultsmartproxy

    proxy = nil
    proxy = MiqProxy.find_by(:id => defaultsmartproxy.to_i) if defaultsmartproxy
    proxy.try(:host)
  end

  def my_zone
    ems = ext_management_system
    ems ? ems.my_zone : MiqServer.my_zone
  end

  def my_zone_obj
    Zone.find_by(:name => my_zone)
  end

  #
  # Proxy methods
  #

  # TODO: Come back to this
  def proxies4job(_job = nil)
    _log.debug("Enter")

    all_proxy_list = storage2proxies
    proxies = storage2active_proxies(all_proxy_list)
    _log.debug("# proxies = #{proxies.length}")

    msg = if all_proxy_list.empty?
            "No active SmartProxies found to analyze this VM"
          elsif proxies.empty?
            "Provide credentials for this VM's Host to perform SmartState Analysis"
          else
            'Perform SmartState Analysis on this VM'
          end

    log_all_proxies(all_proxy_list, msg) if proxies.empty?
    {:proxies => proxies.flatten, :message => msg}
  end

  def log_all_proxies(all_proxy_list, message)
    proxies = all_proxy_list.collect { |a| "[#{log_proxies_format_instance(a)}]" }
    proxies_text = proxies.empty? ? "[none]" : proxies.join(" -- ")
    _log.warn("Proxies for #{log_proxies_vm_config} : #{proxies_text}")
    _log.warn("Proxies message: #{message}")
  end

  def log_proxies_vm_config
    msg = "[#{log_proxies_format_instance(self)}] on host [#{log_proxies_format_instance(host)}] datastore "
    msg << (storage ? "[#{storage.name}-#{storage.store_type}]" : "No storage")
  end

  def log_proxies_format_instance(object)
    return 'Nil' if object.nil?

    "#{object.class.name}:#{object.id}-#{object.name}:#{object.try(:state)}"
  end

  def storage2proxies
    @storage_proxies ||= begin
      # Support vixDisk scanning of VMware VMs from the vmdb server
      miq_server_proxies
    end
  end

  def storage2active_proxies(all_proxy_list = nil)
    all_proxy_list ||= storage2proxies
    _log.debug("all_proxy_list.length = #{all_proxy_list.length}")
    proxies = all_proxy_list.select(&:is_proxy_active?)
    _log.debug("proxies1.length = #{proxies.length}")

    # MiqServer coresident proxy needs to contact the host and provide credentials.
    # Remove any MiqServer instances if we do not have credentials
    rsc = scan_via_ems? ? ext_management_system : host
    proxies.delete_if { |p| p.is_a?(MiqServer) } if rsc && !rsc.authentication_status_ok?
    _log.debug("proxies2.length = #{proxies.length}")

    proxies
  end

  def has_active_proxy?
    storage2active_proxies.any?
  end

  def has_proxy?
    storage2proxies.any?
  end

  # Cache the servers because the JobProxyDispatch calls this for each Vm scan job in a loop
  cache_with_timeout(:miq_servers_for_scan, 30.seconds) do
    MiqServer.where(:status => "started").includes([:zone, :server_roles]).to_a
  end

  def miq_server_proxies
    case vendor
    when 'vmware'
      # VM cannot be scanned by server if they are on a repository
      return [] if storage_id.blank? || repository_vm?
    when 'microsoft'
      return [] if storage_id.blank?
    else
      _log.debug("else")
      return []
    end

    host_server_ids = host ? host.vm_scan_affinity.collect(&:id) : []
    _log.debug("host_server_ids.length = #{host_server_ids.length}")

    storage_server_ids = storages.collect { |s| s.vm_scan_affinity.collect(&:id) }.reject(&:blank?)
    _log.debug("storage_server_ids.length = #{storage_server_ids.length}")

    all_storage_server_ids = storage_server_ids.inject(:&) || []
    _log.debug("all_storage_server_ids.length = #{all_storage_server_ids.length}")

    srs = self.class.miq_servers_for_scan
    _log.debug("srs.length = #{srs.length}")

    miq_servers = srs.select do |svr|
      (svr.vm_scan_host_affinity? ? host_server_ids.detect { |id| id == svr.id } : host_server_ids.empty?) &&
      (svr.vm_scan_storage_affinity? ? all_storage_server_ids.detect { |id| id == svr.id } : storage_server_ids.empty?)
    end
    _log.debug("miq_servers1.length = #{miq_servers.length}")

    miq_servers.select! do |svr|
      result = svr.status == "started" && svr.has_zone?(my_zone)
      result &&= svr.is_vix_disk? if vendor == 'vmware'
      result
    end
    _log.debug("miq_servers2.length = #{miq_servers.length}")
    miq_servers
  end

  def active_proxy_error_message
    proxies4job[:message]
  end

  # TODO: Vmware specific
  def repository_vm?
    host.nil?
  end

  # TODO: Vmware specfic
  def template=(val)
    return val unless val ^ template # Only continue if toggling setting

    write_attribute(:template, val)

    self.type = corresponding_model.name if (template? && kind_of?(Vm)) || (!template? && kind_of?(MiqTemplate))
    d = template? ? [/\.vmx$/, ".vmtx", 'never'] : [/\.vmtx$/, ".vmx", state == 'never' ? 'unknown' : raw_power_state]
    self.location = location.sub(d[0], d[1]) unless location.nil?
    self.raw_power_state = d[2]
  end

  # TODO: Vmware specfic
  def runnable?
    host_id.present? && current_state != "never"
  end

  def self.post_refresh_ems(ems_id, update_start_time)
    update_start_time = update_start_time.utc
    ems = ExtManagementSystem.find(ems_id)

    # Collect the newly added VMs
    added_vms = ems.vms_and_templates.where("created_on >= ?", update_start_time)

    # Create queue items to do additional process like apply tags and link events
    unless added_vms.empty?
      added_vm_ids = []
      added_vms.find_each do |v|
        v.post_create_actions_queue
        added_vm_ids << v.id
      end
    end

    post_refresh_ems_folder_updates(ems, update_start_time, added_vms)
  end

  def self.post_refresh_ems_folder_updates(ems, update_start_time, added_vms)
    # Collect the updated folder relationships to determine which vms need updated path information
    ems_folders = ems.ems_folders
    MiqPreloader.preload(ems_folders, :all_relationships)

    # Find any VMs that were created or moved into a new folder
    updated_vm_rels = ems_folders.collect do |f|
      f.relationships.collect do |r|
        r.children.select do |child_r|
          child_r.resource_type == "VmOrTemplate" &&
            (child_r.created_at >= update_start_time || child_r.updated_at >= update_start_time)
        end
      end
    end.flatten

    # Now find any Folders that were renamed or moved into a new parent folder
    updated_folders = ems_folders.select do |f|
      f.created_on >= update_start_time || f.updated_on >= update_start_time ||  # Has the folder itself changed (e.g. renamed)?
        f.relationships.any? do |r|
          r.created_at >= update_start_time || r.updated_at >= update_start_time # Has the relationship changed (e.g. this folder moved under another folder)?
        end
    end

    updated_vms  = VmOrTemplate.where(:id => updated_vm_rels.collect(&:resource_id))
    updated_vms += updated_folders.flat_map(&:all_vms_and_templates)
    updated_vms  = updated_vms.uniq - added_vms
    updated_vms.each(&:classify_with_parent_folder_path_queue)
  end
  private_class_method :post_refresh_ems_folder_updates

  def post_create_actions_queue
    MiqQueue.submit_job(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'post_create_actions'
    )
  end

  def post_create_actions
    reconnect_events
    classify_with_parent_folder_path
    raise_created_event
  end

  def raise_created_event
    raise NotImplementedError, _("raise_created_event must be implemented in a subclass")
  end

  # TODO: Vmware specific
  # Determines the full path from the Storage and location
  def path
    # If Storage id is blank return the location stored for the vm after removing the uri data
    # Otherwise build the path from the storage data and vm location.
    return location if storage_id.blank?
    # Return location if it contains a fully-qualified file URI
    return location if location.starts_with?('file://')
    # Return location for RHEV-M VMs
    return rhevm_config_path if vendor.to_s.downcase == 'redhat'

    if storage.store_type == "NAS"
      File.join(storage.name, location)
    elsif storage.storage_type_supported_for_ssa?
      "[#{storage.name}] #{location}"
    else
      _log.warn("VM [#{name}] storage type [#{storage.store_type}] not supported")
      @path = location
    end
  end

  def rhevm_config_path
    # /rhev/data-center/<datacenter_id>/mastersd/master/vms/<vm_guid>/<vm_guid>.ovf/
    datacenter = parent_datacenter
    return location if datacenter.blank?

    File.join('/rhev/data-center', datacenter.uid_ems, 'mastersd/master/vms', uid_ems, location)
  end

  def state
    (power_state || "unknown").downcase
  end
  alias_method :current_state, :state

  # Override raw_power_state= attribute setter in order to impose side effects
  # of setting previous_state and updating state_changed_on
  def raw_power_state=(new_state)
    return unless new_state

    unless raw_power_state == new_state
      self.previous_state   = raw_power_state
      self.state_changed_on = Time.now.utc
      super
      self.power_state = calculate_power_state
    end
    new_state
  end

  def self.calculate_power_state(raw_power_state)
    (raw_power_state == "never") ? "never" : "unknown"
  end

  def archived?
    return self["archived"] if  has_attribute?("archived")

    ems_id.nil? && storage_id.nil?
  end
  alias_method :archived, :archived?
  virtual_attribute :archived, :boolean, :arel => (lambda do |t|
    t.grouping(t[:ems_id].eq(nil).and(t[:storage_id].eq(nil)))
  end)

  def orphaned?
    return self["orphaned"] if  has_attribute?("orphaned")

    ems_id.nil? && !storage_id.nil?
  end
  alias_method :orphaned, :orphaned?
  virtual_attribute :orphaned, :boolean, :arel => (lambda do |t|
    t.grouping(t[:ems_id].eq(nil).and(t[:storage_id].not_eq(nil)))
  end)

  def active?
    return self["active"] if  has_attribute?("active")

    !archived? && !orphaned? && !retired? && !template?
  end
  alias_method :active, :active?
  # in sql nil != false ==> false
  virtual_attribute :active, :boolean, :arel => (lambda do |t|
    t.grouping(t[:ems_id].not_eq(nil)
     .and(t[:retired].eq(nil).or(t[:retired].eq(t.create_false)))
     .and(t[:template].eq(nil).or(t[:template].eq(t.create_false))))
  end)

  def disconnected?
    return self["disconnected"] if has_attribute?("disconnected")

    !connected_to_ems?
  end
  virtual_attribute :disconnected, :boolean, :arel => (lambda do |t|
    t.grouping(t[:connection_state].not_eq(nil).and(t[:connection_state].not_eq("connected")))
  end)
  alias_method :disconnected, :disconnected?

  def normalized_state
    return self["normalized_state"] if has_attribute?("normalized_state")

    %w[archived orphaned template retired disconnected].each do |s|
      return s if send(:"#{s}?")
    end
    return power_state.downcase unless power_state.nil?

    "unknown"
  end
  virtual_attribute :normalized_state, :string, :arel => (lambda do |t|
    t.grouping(
      Arel::Nodes::Case.new
      .when(arel_table[:archived]).then(Arel.sql("'archived'"))
      .when(arel_table[:orphaned]).then(Arel.sql("'orphaned'"))
      .when(t[:template].eq(t.create_true)).then(Arel.sql("'template'"))
      .when(t[:retired].eq(t.create_true)).then(Arel.sql("'retired'"))
      .when(arel_table[:disconnected]).then(Arel.sql("'disconnected'"))
      .else(t.lower(
              t.coalesce([t[:power_state], Arel.sql("'unknown'")])
      ))
    )
  end)

  def classify_with_parent_folder_path_queue(add = true)
    MiqQueue.submit_job(
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => 'classify_with_parent_folder_path',
      :args        => [add],
      :priority    => MiqQueue::MIN_PRIORITY
    )
  end

  def classify_with_parent_folder_path(add = true)
    [:blue, :yellow].each do |folder_type|
      path = send(:"parent_#{folder_type}_folder_path")
      next if path.blank?

      cat = self.class.folder_category(folder_type)
      ent = self.class.folder_entry(path, cat)

      _log.info("#{add ? "C" : "Unc"}lassifying VM: [#{name}] with Category: [#{cat.name} => #{cat.description}], Entry: [#{ent.name} => #{ent.description}]")
      ent.send(add ? :assign_entry_to : :remove_entry_from, self, false)
    end
  end

  def self.folder_category(folder_type)
    cat_name = "folder_path_#{folder_type}"
    cat = Classification.lookup_by_name(cat_name)
    unless cat
      cat = Classification.is_category.new(
        :name         => cat_name,
        :description  => "Parent Folder Path (#{folder_type == :blue ? "VMs & Templates" : "Hosts & Clusters"})",
        :single_value => true,
        :read_only    => true
      )
      cat.save(:validate => false)
    end
    cat
  end

  def self.folder_entry(ent_desc, cat)
    ent_name = ent_desc.downcase.tr(" ", "_").split("/").join(":")
    ent = cat.find_entry_by_name(ent_name)
    unless ent
      ent = cat.children.new(:name => ent_name, :description => ent_desc)
      ent.save(:validate => false)
    end
    ent
  end

  def event_where_clause(assoc = :ems_events)
    case assoc.to_sym
    when :ems_events, :event_streams
      ["vm_or_template_id = ? OR dest_vm_or_template_id = ? ", id, id]
    when :policy_events
      ["target_id = ? and target_class = ? ", id, self.class.base_class.name]
    end
  end

  # Virtual columns for owning resource pool, folder and datacenter
  def v_owning_cluster
    o = owning_cluster
    o ? o.name : ""
  end

  def v_owning_resource_pool
    o = owning_resource_pool
    o ? o.name : ""
  end

  def v_owning_folder
    o = owning_folder
    o ? o.name : ""
  end

  alias_method :v_owning_folder_path, :owning_folder_path

  def v_owning_blue_folder
    o = owning_blue_folder
    o ? o.name : ""
  end

  alias_method :v_owning_blue_folder_path, :owning_blue_folder_path

  def v_owning_datacenter
    o = owning_datacenter
    o ? o.name : ""
  end

  def v_is_a_template
    template?.to_s.capitalize
  end
  # technically it is capitalized, but for sorting, not a concern
  # but we do need nil to become false
  virtual_attribute :v_is_a_template, :string, :arel => (lambda do |t|
    t.grouping(t.coalesce([t[:template], t.create_false]))
  end)

  def v_datastore_path
    datastorepath = location || ""
    storage ? "#{storage.name}/#{datastorepath}" : datastorepath
  end

  def event_threshold?(options = {:time_threshold => 30.minutes, :event_types => ["MigrateVM_Task_Complete"], :freq_threshold => 2})
    raise _("option :event_types is required")    unless options[:event_types]
    raise _("option :time_threshold is required") unless options[:time_threshold]
    raise _("option :freq_threshold is required") unless options[:freq_threshold]

    EmsEvent
      .where(:event_type => options[:event_types])
      .where("vm_or_template_id = :id OR dest_vm_or_template_id = :id", :id => id)
      .where("timestamp >= ?", options[:time_threshold].to_i.seconds.ago.utc)
      .count >= options[:freq_threshold].to_i
  end

  def reconfigured_hardware_value?(options)
    attr = options[:hdw_attr]
    raise _(":hdw_attr required") if attr.nil?

    operator = options[:operator] || ">"
    operator = operator.downcase == "increased" ? ">" : operator.downcase == "decreased" ? "<" : operator

    current_state, prev_state = drift_states.order("timestamp DESC").limit(2)
    if current_state.nil? || prev_state.nil?
      _log.info("Unable to evaluate, not enough state data available")
      return false
    end

    current_value  = current_state.data_obj.hardware.send(attr).to_i
    previous_value = prev_state.data_obj.hardware.send(attr).to_i
    result         = current_value.send(operator, previous_value)
    _log.info("Evaluate: (Current: #{current_value} #{operator} Previous: #{previous_value}) = #{result}")

    result
  end

  def changed_vm_value?(options)
    attr = options[:attr] || options[:hdw_attr]
    raise _(":attr required") if attr.nil?

    operator = options[:operator]

    data0, data1 = drift_states.order("timestamp DESC").limit(2)

    if data0.nil? || data1.nil?
      _log.info("Unable to evaluate, not enough state data available")
      return false
    end

    v0 = data0.data_obj.send(attr) || ""
    v1 = data1.data_obj.send(attr) || ""
    if operator.downcase == "changed"
      result = !(v0 == v1)
    else
      raise _("operator '%{operator}' is not supported") % {:operator => operator}
    end
    _log.info("Evaluate: !(#{v1} == #{v0}) = #{result}")

    result
  end

  #
  # Hardware Disks/Memory storage methods
  #

  virtual_delegate :allocated_disk_storage, :used_disk_storage,
                   :to => :hardware, :allow_nil => true, :uses => {:hardware => :disks}, :type => :integer

  virtual_delegate :provisioned_storage, :to => :hardware, :allow_nil => true, :default => 0, :type => :integer
  virtual_delegate :num_disks, :to => :hardware, :allow_nil => true, :default => 0, :type => :integer, :uses => {:hardware => :disks}
  virtual_delegate :num_hard_disks, :to => :hardware, :allow_nil => true, :default => 0, :type => :integer, :uses => {:hardware => :hard_disks}

  def used_storage
    used_disk_storage.to_i + ram_size_in_bytes
  end

  def used_storage_by_state
    used_disk_storage.to_i + ram_size_in_bytes_by_state
  end

  def uncommitted_storage
    provisioned_storage.to_i - used_storage_by_state.to_i
  end

  def thin_provisioned
    hardware.nil? ? false : hardware.disks.any? { |d| d.disk_type == 'thin' }
  end

  def ram_size_by_state
    state == 'on' ? ram_size : 0
  end

  def ram_size_in_bytes_by_state
    ram_size_by_state * 1.megabyte
  end

  def has_rdm_disk
    return false if hardware.nil?

    !hardware.disks.detect(&:rdm_disk?).nil?
  end

  def disks_aligned
    dlist = hardware ? hardware.hard_disks : []
    dlist = dlist.reject(&:rdm_disk?) # Skip RDM disks
    return "Unknown" if dlist.empty?
    return "True"    if dlist.all? { |d| d.partitions_aligned == "True" }
    return "False"   if dlist.any? { |d| d.partitions_aligned == "False" }

    "Unknown"
  end

  def memory_exceeds_current_host_headroom
    return false if host.nil?

    (ram_size > host.current_memory_headroom)
  end

  def collect_running_processes(_options = {})
    OsProcess.add_elements(self, running_processes)
    operating_system.save unless operating_system.nil?
  end

  def ipaddresses
    hardware.nil? ? [] : hardware.ipaddresses
  end

  def hostnames
    hardware.nil? ? [] : hardware.hostnames
  end

  def mac_addresses
    hardware.nil? ? [] : hardware.mac_addresses
  end

  def processes
    operating_system.nil? ? [] : operating_system.processes
  end

  def event_logs
    operating_system.nil? ? [] : operating_system.event_logs
  end

  def direct_service
    direct_services.first
  end

  def service
    direct_service.try(:root_service)
  end

  def has_required_host?
    !host.nil?
  end

  def has_active_ems?
    return true unless ext_management_system.nil?

    false
  end

  #
  # Metric methods
  #

  PERF_ROLLUP_CHILDREN = []

  def perf_rollup_parents(interval_name = nil)
    [host, service].compact unless interval_name == 'realtime'
  end

  # Called from integrate ws to kick off scan for vdi VMs
  def self.vms_by_ipaddress(ipaddress)
    ipaddresses = ipaddress.split(',')
    Network.where("ipaddress in (?)", ipaddresses).each do |network|
      begin
        vm = network.hardware.vm
        yield(vm)
      rescue
      end
    end
  end

  # This creates the following SQL conditional:
  #
  #   1 = (SELECT 1
  #        FROM hardwares
  #        JOIN networks ON networks.hardware_id = hardwares.id
  #        WHERE hardwares.vm_or_template_id = vms.id
  #          AND (networks.ipaddress LIKE "%IPADDRESS%"
  #               OR networks.ipv6address LIKE "%IPADDRESS%")
  #        LIMIT 1
  #       )
  #
  # This is simply an existance check, so when one record is found matching the
  # following conditions:
  #
  #   - It is a hardware record that is associated with the vm
  #   - It has an ipaddress or ipv6address that matches the search
  #
  # It will return the VM record.
  def self.miq_expression_includes_any_ipaddresses_arel(ipaddress)
    vms       = arel_table
    networks  = Network.arel_table
    hardwares = Hardware.arel_table

    match_grouping = networks[:ipaddress].matches("%#{ipaddress}%")
                       .or(networks[:ipv6address].matches("%#{ipaddress}%"))

    query = hardwares.project(1)
                     .join(networks).on(networks[:hardware_id].eq(hardwares[:id]))
                     .where(hardwares[:vm_or_template_id].eq(vms[:id]).and(match_grouping))
                     .take(1)
    Arel.sql("1").eq(query)
  end

  def self.scan_by_property(property, value, _options = {})
    _log.info("scan_vm_by_property called with property:[#{property}] value:[#{value}]")
    case property
    when "ipaddress"
      vms_by_ipaddress(value) do |vm|
        if vm.state == "on"
          _log.info("Initiating VM scan for [#{vm.id}:#{vm.name}]")
          vm.scan
        end
      end
    else
      raise _("Unsupported property type [%{property}]") % {:property => property}
    end
  end

  def self.event_by_property(property, value, event_type, event_message, event_time = nil, _options = {})
    _log.info("event_vm_by_property called with property:[#{property}] value:[#{value}] type:[#{event_type}] message:[#{event_message}] event_time:[#{event_time}]")
    event_timestamp = event_time.blank? ? Time.now.utc : event_time.to_time(:utc)

    case property
    when "ipaddress"
      vms_by_ipaddress(value) do |vm|
        vm.add_ems_event(event_type, event_message, event_timestamp)
      end
    when "uid_ems"
      vm = VmOrTemplate.find_by(:uid_ems => value)
      unless vm.nil?
        vm.add_ems_event(event_type, event_message, event_timestamp)
      end
    else
      raise _("Unsupported property type [%{property}]") % {:property => property}
    end
  end

  def add_ems_event(event_type, event_message, event_timestamp)
    event = {
      :event_type        => event_type,
      :is_task           => false,
      :source            => 'EVM',
      :message           => event_message,
      :timestamp         => event_timestamp,
      :vm_or_template_id => id,
      :vm_name           => name,
      :vm_location       => path,
    }
    event[:ems_id] = ems_id unless ems_id.nil?

    unless host_id.nil?
      event[:host_id]   = host_id
      event[:host_name] = host.name
    end

    EmsEvent.add(ems_id, event)
  end

  def console_supported?(_type)
    false
  end

  # Stop certain charts from showing unless the subclass allows
  def non_generic_charts_available?
    false
  end
  alias_method :cpu_ready_available?,    :non_generic_charts_available?
  alias_method :cpu_mhz_available?,      :non_generic_charts_available?
  alias_method :cpu_percent_available?,  :non_generic_charts_available?
  alias_method :memory_mb_available?,    :non_generic_charts_available?

  def self.includes_template?(ids)
    MiqTemplate.where(:id => ids).exists?
  end

  supports :destroy

  # Stop showing Reconfigure VM task unless the subclass allows
  def reconfigurable?
    false
  end

  def self.reconfigurable?(ids)
    vms = VmOrTemplate.where(:id => ids)
    return false if vms.blank?

    vms.all?(&:reconfigurable?)
  end

  PUBLIC_TEMPLATE_CLASSES = %w[ManageIQ::Providers::Openstack::CloudManager::Template].freeze

  def self.tenant_id_clause(user_or_group)
    template_tenant_ids = MiqTemplate.accessible_tenant_ids(user_or_group, Rbac.accessible_tenant_ids_strategy(MiqTemplate))
    vm_tenant_ids       = Vm.accessible_tenant_ids(user_or_group, Rbac.accessible_tenant_ids_strategy(Vm))
    return if template_tenant_ids.empty? && vm_tenant_ids.empty?

    tenant = user_or_group.current_tenant
    tenant_vms       = "vms.template = false AND vms.tenant_id IN (?)"
    public_templates = "vms.template = true AND vms.publicly_available = true AND vms.type IN (?)"
    tenant_templates = "vms.template = true AND vms.tenant_id IN (?)"

    if tenant.source_id
      private_tenant_templates = "vms.template = true AND vms.tenant_id = (?) AND vms.publicly_available = false"
      tenant_templates += " AND vms.type NOT IN (?)"
      ["#{private_tenant_templates} OR #{tenant_vms} OR #{tenant_templates} OR #{public_templates}", tenant.id, vm_tenant_ids, template_tenant_ids, PUBLIC_TEMPLATE_CLASSES, PUBLIC_TEMPLATE_CLASSES]
    else
      ["#{tenant_templates} OR #{public_templates} OR #{tenant_vms}", template_tenant_ids, PUBLIC_TEMPLATE_CLASSES, vm_tenant_ids]
    end
  end

  def self.with_ownership
    includes(:ext_management_system).where(:ext_management_systems => {:tenant_mapping_enabled => [false, nil]})
  end

  def tenant_identity
    user = evm_owner
    user = User.super_admin.tap { |u| u.current_group = miq_group } if user.nil? || !user.miq_group_ids.include?(miq_group_id)
    user
  end

  supports(:console) { N_("Console not supported") unless console_supported?('spice') || console_supported?('vnc') }

  def child_resources
    children
  end

  def parent_resource
    parent
  end

  def self.display_name(number = 1)
    n_('VM or Template', 'VMs or Templates', number)
  end

  private

  def power_state=(new_power_state)
    super
  end

  def calculate_power_state
    self.class.calculate_power_state(raw_power_state)
  end

  # deprecated, use unsupported_reason(:action) instead
  def check_feature_support(_message_prefix)
    reason = unsupported_reason(:action)
    [!reason, reason]
  end

  def create_notification(type, options)
    Notification.create!(
      :type    => type,
      :subject => self,
      :options => options
    )
  end

  def command_queue_options(queue_options)
    {
      :class_name  => self.class.name,
      :instance_id => id,
      :role        => "ems_operations",
      :queue_name  => queue_name_for_ems_operations,
      :zone        => my_zone,
    }.merge(queue_options)
  end
end
