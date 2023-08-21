# opswalrus

opswalrus is a tool that runs scripts against hosts. It's kind of like Ansible, but aims to be simpler to use.

# Getting started

You have two options:
- Install via Rubygems
- Install via Docker

## Rubygems install

```shell
gem install opswalrus

ops version
```

## Docker install

```shell
alias ops='docker run --rm -it -v $HOME/.ssh:/root/.ssh -v /var/run/docker.sock:/var/run/docker.sock -v ${PWD}/:/workdir ghcr.io/opswalrus/ops'

ops version
```

# Examples

```bash
> ops run core/host info
{
  success: true,
  host: {
    name: "davidlinux",
    os: "Ubuntu 23.04 (lunar)",
    kernel: "Linux 6.2.0-1007-lowlatency x86_64 GNU/Linux",
  }
}
```

# Packages and Imports

## Ops Packages

An ops package is a directory containing a package.yml (or package.yaml) file.

- The package.yml (or package.yaml) file is called the package file.
- The directory containing the package file is called the package directory.

A package file looks like this:
```yaml
author: David Ellis
license: MIT
version: 1.0.0
dependencies:
  core: davidkellis/ops_core
  apt: davidkellis/ops_apt
```

## Ops Files

An ops package may also consist of ops files, arranged in an arbitrary directory structure.

- An ops file is a script to do do something, very much like a shell script.
- An ops file should try to implement an idempotent operation, such that repeated execution of the script results in the same desired state.

An ops file looks like this:
```
params:
  ops_username: string
  ops_ssh_public_key: string
  hostname: string

output:
  success: boolean,
  error: string?

imports:
  core: core        # core references the bundled core package referenced in the package.yaml
  svc: service      # service references the bundled service package referenced in the package.yaml
...

desc "create the admin group if it doens't exist"
core.create_group name: "admin"

desc "set up passwordless sudo for admin group users"
core.replace_line file: "/etc/sudoers",
                  pattern: "^%admin",
                  line: "%admin ALL=(ALL) NOPASSWD: ALL",
                  verify: "/usr/sbin/visudo -cf %s"

desc "create the ops user and make it an admin user"
core.create_user name: params.ops_username

desc "set up authorized key for id_ansible ssh key (root user)"
core.ssh.add_authorized_key user: "root", key: ops_ssh_public_key

desc "set up authorized key for id_ansible ssh key (ops user)"
core.ssh.add_authorized_key user: ops_username, key: ops_ssh_public_key

desc "disable password authentication for root"
core.replace_line file: '/etc/ssh/sshd_config',
                  pattern: '^#?PermitRootLogin',
                  line: 'PermitRootLogin prohibit-password'

desc "restart sshd"
svc.restart name: "sshd"

{
  success: true,
}
```

An ops file is broken up into two parts. The first part is an optional YAML block that describes the structure of the expected
input parameters, the structure of the expected JSON output message, and the package dependencies that the script
needs in order to run.

The YAML block is concluded with an elipsis, `...`, on a line by itself.

The YAML block and its associated trailing elipsis may be omitted.

Following the elipsis that concludes the YAML block is a block of Ruby code. The block of Ruby is executed with a number
of methods, constants, and libraries that are available as a kind of domain specific language (DSL). This DSL makes
writing ops scripts feel very much like writing standard bash shell scripts.

Ops file imports are a mapping consisting of a local name and a corresponding package reference.

## Package Bundles

When an ops file is run, the ops runtime will first bundle up the invoked ops file as well as all package dependencies
and place the bundle of associated ops packages and ops files into an ops bundle directory.

The bundle directory is named ops_bundle, and contains everything needed to run the specified ops file on either the
local host or a remote host.

The ops command will place the bundle directory in the directory from which the ops command is being run. So, if `pwd`
returns `/home/david/foo` and the ops command is run from within that directory, then the bundle directory will be placed
at `/home/david/foo/ops_bundle`.

The one exception to the normal bundle directory placement rule described in the previous paragraph is when the ops
command is being run from within a directory that is contained within a package directory. In that case, the bundle directory
will be placed inside the package directory. So, for example, if the directory structure looks like:
```
❯ tree pkg
pkg
├── apt
│   ├── install.ops
│   └── update.ops
├── core
│   ├── echo.ops
│   ├── host
│   │   ├── info.ops
│   │   └── info.rb
│   ├── package.yaml
│   ├── ssh_copy_id.ops
│   ├── touch.ops
│   └── whoami.ops
├── hardening
│   └── package.yaml
├── motd
│   ├── motd.ops
│   └── package.yaml
└── service
    └── restart.ops
```
and the `pwd` command returns `pkg/core/host`, and the ops command is run from within `pkg/core/host`, then the bundle
directory will be placed at `pkg/core/ops_bundle`.

### Bundle Directory Contents

A bundle directory contains all the dependencies for a given ops file invocation. There are two possible cases:
1. The invoked ops file is part of a package
2. The invoked ops file is not part of a package

In case (1), when the ops file being invoked is part of a package, we'll call it P, then the bundle directory will contain
a copy of the package directory associated with P, as well as all of the package directories associated with all
transitive package dependencies of P. For example, if the ops file foo.ops is contained within the package directory
for the Bar package, and if the Bar package depends on the core package and the service package, then the
directory structure of the bundle directory would be:
```
❯ tree ops_bundle
ops_bundle
├── Bar
│   └── foo.ops
├── core
│   ├── echo.ops
│   ├── host
│   │   ├── info.ops
│   │   └── info.rb
│   ├── package.yaml
│   ├── ssh_copy_id.ops
│   ├── touch.ops
│   └── whoami.ops
└── service
    └── restart.ops
```

In case (2), when the ops file being invoked is not part of a package, then the bundle directory will contain a copy
of the package directories associated with all transitive package dependencies of the ops file being invoked.
Additionally, the deepest nested directory containing all of the transitive ops file dependencies of the ops file being
invoked will be copied to the bundle directory.

## Import and Symbol Resolution

When the ops command bundles and runs an ops file, the rules that the runtime uses to resolve references to other ops
files is as follows; assume the following sample project directory structure:

Project directory structure:
```
davidinfra
├── caddy
│   ├── install
│   │   └── debian.ops
│   └── install.ops
├── hosts.yaml
├── main.ops
├── prepare_host
│   ├── all.ops
│   ├── hostname.ops
│   └── ssh.ops
└── roles
    └── web.ops
```

Corresponding bundle directory structure:
```
davidinfra
├── ops_bundle
│   ├── core
│   │   └──...
│   └── davidinfra
│       ├── caddy
│       │   ├── install
│       │   │   ├── debian.ops
│       │   │   └── install.ops
│       │   └── restart.ops
│       ├── hosts.yaml
│       ├── main.ops
│       ├── prepare_host
│       │   ├── all.ops
│       │   ├── hostname.ops
│       │   └── ssh.ops
│       └── roles
│           └── web.ops
├── caddy
│   ├── install
│   │   └── debian.ops
│   │   └── install.ops
│   └── restart.ops
├── hosts.yaml
├── main.ops
├── prepare_host
│   ├── all.ops
│   ├── hostname.ops
│   └── ssh.ops
└── roles
    └── web.ops
```

The import and symbol resolution rules are as follows:

1. An ops file implicitly imports all sibling ops files and directories that reside within its same parent directory.
   Within the lexical scope of an ops file's ruby script, any ops files or subdirectories that are implicitly imported
   may be referenced by their name.
   For example:
   - main.ops may invoke caddy/install.ops with the expression `caddy.restart(...)`
   - all.ops may invoke hostname.ops with the expression `hostname(...)`
2. If there is an ops file and a directory that share the same name (with the exception of the .ops file extension), and
   are both contained by the same parent directory, then only the .ops file may be referenced and invoked by other ops files.
   The directory of the same name will be treated as a library directory and if there is a Ruby source file in the library
   directory with the same name, then that ruby file will automatically be loaded. Other ruby files within the library directory
   will be required/loaded as instructed by the entrypoint .rb file.
3. If there is an ops file and a directory that share the same name (with the exception of the .ops file extension), and
   the ops file is contained by the directory of the same name, then the ops file is considered to be the primary API
   interface for a sub-module that is implemented by the ops files and ruby scripts contained within the directory.
   Consequently, the directory containing the ops file of the same name (with the exception of the .ops file extension)
   may be invoked as if it were the primary API interface ops file.
   For example:
   - main.ops may invoke `caddy.install(...)` as a shorthand syntax for `caddy.install.install(...)`
   - install.ops may invoke `debian(...)`, and reference other files or subpackages within the caddy/install directory
4. Ops files may import packages or relative paths:
   1. a package reference that matches one of the local package names in the dependencies captured in packages.yaml
   2. a package reference that resolves to a relative path pointing at a package directory
   3. a relative path that resolves to a directory containing ops files
   4. a relative path that resolves to an ops file
