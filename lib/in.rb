#!/usr/bin/env ruby

require 'fileutils'
require_relative 'utils'

# ResourceIn implements the `in` command to download a ref.
class ResourceIn
  include Utils

  SSH_DIR = File.expand_path('~/.ssh')
  SSH_CONFIG_FILE = File.join(SSH_DIR, 'config')
  SSH_KEY_FILE = File.join(SSH_DIR, 'github.key')
  SSH_CONFIGURATION = <<-EOF.gsub(/^ {4}/, '')
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    Host github.com
      IdentityFile #{SSH_KEY_FILE}
  EOF

  # Create a constructor that allows injection of parameters
  # mostly for testing or for defining custom clients and configs.
  #
  # @param client [Octokit::Client] Github client to use for requests
  # @param config [Hash] Configuration hash
  def initialize(client: nil, config: nil)
    @client = client unless client.nil?
    @config = config unless config.nil?
  end

  # Clone the repository into the source path at some PR ref.
  # Shells out to git.
  #
  # @param uri    [String]  The name of the repository.
  # @param pkey   [String]  Private key to check out with
  # @param pr_num [Integer] The PR number.
  # @param dir    [String]  Directory to clone to
  def self.clone(uri, pkey, pr_num, dir)
    unless pkey.nil?
      write_ssh_config
      write_private_key(pkey)
    end

    status = spawn('git', 'clone', '--depth', '1', uri, dir)
    fail StandardError, "failed to clone repo: #{uri}" unless status.success?

    Dir.chdir(dir) do
      checkout_pr(pr_num)
    end
  end

  # Fetch and checkout a pr
  #
  # @param pr_num [Integer] The PR number.
  def self.checkout_pr(pr_num)
    cmds = [
      "git fetch --depth 1 origin refs/pull/#{pr_num}/head:pr",
      'git checkout pr',
      'git submodule --init --recursive'
    ]

    cmds.each do |cmd|
      status = spawn(*cmd.split(' '))
      fail StandardError, "failed running: #{cmd}" unless status.success?
    end
  end

  # Create the ssh_dir if it doesn't exist
  def self.create_ssh_dir
    return if Dir.exist?(SSH_DIR)

    FileUtils.mkdir_p(SSH_DIR)
    FileUtils.chmod(0700, SSH_DIR)
  end

  # Write an ssh_config in order to force git to use these settings
  def self.write_ssh_config
    return if File.exist?(SSH_CONFIG_FILE)

    create_ssh_dir

    File.open(SSH_CONFIG_FILE, 'w') do |f|
      f.write(SSH_CONFIGURATION)
    end
    FileUtils.chmod(0600, SSH_CONFIG_FILE)
  end

  # Write a private key file to where write_ssh_config will point to
  #
  # @param private_key [String] The private key to write
  def self.write_private_key(private_key)
    return if File.exist?(SSH_KEY_FILE)

    create_ssh_dir

    File.open(SSH_KEY_FILE, 'w') do |f|
      f.write(private_key)
    end
    FileUtils.chmod(0600, SSH_KEY_FILE)
  end

  # Get the metadata for a given commit and coerce it into a nicer format
  #
  # @param client [Octokit::Client] Github client
  # @param repo   [String] Repo name
  # @param sha    [String] Commit hash of the thing to get
  def self.get_commit_metadata(client, repo, sha)
    c = client.commit(repo, sha)
    commit = c.commit

    [
      { name: 'commit', value: c.sha },
      { name: 'author', value: commit.author.name },
      { name: 'author_date', value: commit.author.date },
      { name: 'committer', value: commit.committer.name },
      { name: 'committer_date', value: commit.committer.date },
      { name: 'message', value: commit.message }
    ]
  end

  # Parse the version in the form: pr45:sha into its parts:
  # [45, "sha"]
  #
  # @param version [String] The version to parse.
  # @return        [Array] The two parts of the version string
  def self.parse_version(version)
    parts = version.split(':')
    parts[0] = parts[0].gsub(/pr/, '').to_i
    parts
  end

  # out_path is the output path specified by concourse
  #
  # @return [String] The full path to the file to output
  def out_path
    return @out_path if @out_path
    outdir = ARGV.first
    assert outdir, 'Output directory not supplied'
    @out_path = outdir
  end

  # Clone PR into the given directory
  #
  # @return [String] The result of the in is as per concourse docs.
  #                  A hash containing version & metadata, the metadata provided
  #                  here is essentially the git commit information.
  def run
    source = config['source']
    version = config['version']
    pr_num, sha = ResourceIn.parse_version(version)

    uri = source['uri']
    repo = get_repo_name(uri)

    meta = ResourceIn.get_commit_metadata(client, repo, sha)
    ResourceIn.clone(uri, source['private_key'], pr_num, out_path)

    { version: sha, metadata: meta }
  end
end
