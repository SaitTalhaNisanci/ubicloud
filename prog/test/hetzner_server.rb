# frozen_string_literal: true

require_relative "../../lib/util"

class Prog::Test::HetznerServer < Prog::Base
  def self.assemble
    server_id = Config.ci_hetzner_sacrificial_server_id
    if server_id.nil? || server_id.empty?
      fail "CI_HETZNER_SACRIFICIAL_SERVER_ID must be a nonempty string"
    end
    Strand.create_with_id(
      prog: "Test::HetznerServer",
      label: "start",
      stack: [{server_id: server_id}]
    )
  end

  label def start
    hop_fetch_hostname
  end

  label def fetch_hostname
    current_frame = strand.stack.first
    current_frame["hostname"] = hetzner_api.get_main_ip4
    strand.modified!(:stack)
    strand.save_changes

    hop_add_ssh_key
  end

  label def add_ssh_key
    keypair = SshKey.generate

    hetzner_api.add_key("ubicloud_ci_key_#{strand.ubid}", keypair.public_key)

    current_frame = strand.stack.first
    current_frame["hetzner_ssh_keypair"] = Base64.encode64(keypair.keypair)
    strand.modified!(:stack)
    strand.save_changes

    hop_reset
  end

  label def reset
    hetzner_api.reset(
      frame["server_id"],
      hetzner_ssh_key: hetzner_ssh_keypair.public_key
    )

    hop_wait_reset
  end

  label def wait_reset
    begin
      Util.rootish_ssh(frame["hostname"], "root", [hetzner_ssh_keypair.private_key], "echo 1")
    rescue
      nap 15
    end

    hop_setup_host
  end

  label def setup_host
    st = Prog::Vm::HostNexus.assemble(
      frame["hostname"],
      provider: "hetzner",
      hetzner_server_identifier: frame["server_id"]
    )

    current_frame = strand.stack.first
    current_frame["vm_host_id"] = st.id
    strand.modified!(:stack)
    strand.save_changes

    # BootstrapRhizome::start will override raw_private_key_1, so save the key in
    # raw_private_key_2. This will allow BootstrapRhizome::setup to do a root
    # ssh into the server.
    Sshable[st.id].update(raw_private_key_2: hetzner_ssh_keypair.keypair)

    strand.add_child(st)

    hop_wait_setup_host
  end

  label def wait_setup_host
    reap

    hop_test_host_encrypted if children_idle

    donate
  end

  label def test_host_encrypted
    strand.add_child(Prog::Test::VmGroup.assemble(storage_encrypted: true))

    hop_wait_test_host_encrypted
  end

  label def wait_test_host_encrypted
    reap

    hop_test_host_unencrypted if children_idle

    donate
  end

  label def test_host_unencrypted
    strand.add_child(Prog::Test::VmGroup.assemble(storage_encrypted: false))

    hop_wait_test_host_unencrypted
  end

  label def wait_test_host_unencrypted
    reap

    hop_delete_key if children_idle

    donate
  end

  def children_idle
    active_children = strand.children_dataset.where(Sequel.~(label: "wait"))
    active_semaphores = strand.children_dataset.join(:semaphore, strand_id: :id)

    active_children.count == 0 and active_semaphores.count == 0
  end

  label def delete_key
    hetzner_api.delete_key(hetzner_ssh_keypair.public_key)

    hop_finish
  end

  label def finish
    Strand[vm_host.id].destroy
    vm_host.destroy
    sshable.destroy

    pop "HetznerServer tests finished!"
  end

  def hetzner_api
    @hetzner_api ||= Hosting::HetznerApis.new(
      HetznerHost.new(server_identifier: frame["server_id"])
    )
  end

  def hetzner_ssh_keypair
    @hetzner_ssh_keypair ||= SshKey.from_binary(Base64.decode64(frame["hetzner_ssh_keypair"]))
  end

  def vm_host
    @vm_host ||= VmHost[frame["vm_host_id"]]
  end

  def sshable
    @sshable ||= Sshable[frame["vm_host_id"]]
  end
end
