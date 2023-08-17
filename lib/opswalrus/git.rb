require "git"

module OpsWalrus
  class Git
    # repo?("davidkellis/arborist") -> "https://github.com/davidkellis/arborist"
    # returns the repo URL or directory path
    def self.repo?(repo_reference)
      if Dir.exist?(repo_reference)
        ::Git.ls_remote(repo_reference) && repo_reference rescue nil
      else
        candidate_repo_references = [
          repo_reference,
          repo_reference =~ /(\.(com|net|org|dev|io|local))\// && "https://#{repo_reference}",
          repo_reference !~ /github\.com\// && repo_reference =~ /^[a-z\d](?:[a-z\d]|-(?=[a-z\d])){0,38}\/([\w\.@\:\-~]+)$/i && "https://github.com/#{repo_reference}"    # this regex is from https://www.npmjs.com/package/github-username-regex and https://www.debuggex.com/r/H4kRw1G0YPyBFjfm
        ].compact
        working_repo_reference = candidate_repo_references.find {|reference| ::Git.ls_remote(reference) rescue nil }
        working_repo_reference
      end
    end

  end
end
