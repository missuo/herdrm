import Foundation

/// The POSIX sh probe behind the per-Space Project panel. It runs on the Space's
/// device (locally under `/bin/sh`, or as one `ssh` command) and prints one frame:
/// listening sockets with their owning processes, Docker compose projects and
/// containers, systemd user units, project files and local VMs. `ProjectProbeParser`
/// reads it back; the layout below is that contract.
///
/// Arguments: `$1` comma-separated sections, `$2` interval, `$3` frame count
/// (0 = forever), then one working directory per project root.
///
/// ```
/// @@pp-begin 1
/// @@tools / @@host / @@roots / @@listeners ss|lsof / @@pids | @@ps + @@psc + @@lsofp
/// @@units / @@files <root> / @@env <file>   (env lines are `<lineno>:<KEY>`, never values)
/// @@host (again: the docker lines) / @@compose / @@containers   (slowest tools last)
/// @@vms parallels|vmpal|lima   (each followed by JSON or `@@absent <tool>`)
/// @@error <section>            (anywhere, then up to 3 lines of stderr)
/// @@pp-end
/// ```
public enum ProjectProbeScript {
    public static let protocolVersion = 1
    public static let allSections = ["tools", "host", "roots", "listeners", "pids", "compose", "containers", "units", "files", "env", "vms"]

    static let source = #"""
# PATH mirrors SSHTunnel.remotePathExport (sshd exec is not a login shell), plus sbin for ss/lsof.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH; export PATH
for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && PATH="$d:$PATH"; done
PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.grok/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
LC_ALL=C; export LC_ALL
sections=",${1:-},"; iv=${2:-15}; frames=${3:-1}
[ $# -ge 3 ] && shift 3
os=$(uname -s)
# Without mktemp, stderr detail is dropped rather than written to a guessable path.
errf=$(mktemp 2>/dev/null) || errf=/dev/null
cleanup() { [ "$errf" = /dev/null ] || rm -f "$errf"; }
trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM PIPE

has() { case "$sections" in *",$1,"*) return 0;; esac; return 1; }
have() { command -v "$1" >/dev/null 2>&1; }
# macOS has no timeout(1). perl's alarm survives exec, so the tool itself is
# killed after 8 s; that also closes its end of our stdout. Without it a hung
# tool (a wedged Docker daemon, a stale NFS cwd) would hold the probe forever:
# the TERM trap only runs once the foreground command returns.
if have timeout; then tm() { timeout 8 "$@"; }
elif have perl; then tm() { perl -e 'alarm shift; exec @ARGV or exit 127' 8 "$@"; }
else tm() { "$@"; }; fi
# errdetail: the first stderr lines, with nothing that could pass for a frame header.
errdetail() { head -3 "$errf" | cut -c1-300 | grep -v '^@@'; return 0; }
# run <section> <cmd...>: a failure becomes `@@error <section>` plus the first stderr lines.
run() {
  rn=$1; shift
  if "$@" 2>"$errf"; then :; else
    echo "@@error $rn"; errdetail
  fi
}
# runq: like run, but lsof exits 1 when it found nothing to list; that is an error only if it said so on stderr.
runq() {
  rn=$1; shift
  "$@" 2>"$errf"; rq=$?
  if [ $rq -ne 0 ] && { [ $rq -ne 1 ] || [ -s "$errf" ]; }; then
    echo "@@error $rn"; errdetail
  fi
}
# find_files <root>: find's stdout is filtered here (no `@@` lines, no control characters) and
# find's own exit status is returned, so `run` can still report its stderr.
find_files() {
  ff=$(tm find "$1" -xdev -maxdepth 4 \( -name node_modules -o -name .git -o -name .venv -o -name dist -o -name build -o -name .next \) -prune -o -type f \( -name package.json -o -name 'docker-compose*.y*ml' -o -name 'compose*.y*ml' -o -name Makefile -o -name Procfile -o -name pyproject.toml -o -name Caddyfile -o -name justfile -o -name '.dev-lane.env' -o -name '.env*' \) -print); frc=$?
  [ -n "$ff" ] && printf '%s\n' "$ff" | head -200 | grep -v -E '^@@|[[:cntrl:]]'
  return $frc
}
# Project roots: the git toplevel of each cwd, or the cwd itself.
root_of() {
  rd=$1
  rt=$(cd "$rd" 2>/dev/null && tm git rev-parse --show-toplevel 2>/dev/null)
  echo "${rt:-$rd}"
}
# Linux: one `@@pids` line per process.
emit_pid() {
  ep=$1
  [ -d "/proc/$ep" ] || return 0
  epp=$(awk '/^PPid:/{print $2}' "/proc/$ep/status" 2>/dev/null)
  ecomm=$(cat "/proc/$ep/comm" 2>/dev/null)
  ecwd=$(readlink "/proc/$ep/cwd" 2>/dev/null)
  eunit=$(awk -F/ '{for(i=NF;i>0;i--) if($i ~ /\.service$/){print $i; exit}}' "/proc/$ep/cgroup" 2>/dev/null)
  eout=$(readlink "/proc/$ep/fd/1" 2>/dev/null)
  eargs=$(tr '\0\t\n' '   ' < "/proc/$ep/cmdline" 2>/dev/null | cut -c1-300)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$ep" "$epp" "$ecomm" "$ecwd" "$eunit" "$eout" "${eargs:-$ecomm}"
}

n=0
while :; do
  echo "@@pp-begin PROTOCOL_VERSION"

  if has tools; then
    echo "@@tools"
    for t in git docker ss lsof systemctl prlctl vmpal limactl; do
      tp=$(command -v "$t" 2>/dev/null); echo "$t ${tp:--}"
    done
  fi

  if has host; then
    echo "@@host"
    echo "os $os"; echo "hostname $(hostname 2>/dev/null || uname -n)"
    echo "home $HOME"
    if [ "$os" = Linux ]; then
      echo "ncpu $(getconf _NPROCESSORS_ONLN 2>/dev/null)"
      read -r l1 l5 l15 _ < /proc/loadavg; echo "load $l1 $l5 $l15"
      while read -r k v _; do
        case $k in MemTotal:) echo "memtotal_kb $v";; MemAvailable:) echo "memavail_kb $v";; esac
      done < /proc/meminfo
      read -r up _ < /proc/uptime; echo "uptime $up"
    else
      echo "ncpu $(sysctl -n hw.ncpu 2>/dev/null)"
      echo "load $(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
      echo "memtotal_kb $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"
      echo "now $(date +%s)"
      echo "boottime $(sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ *sec = \([0-9]*\).*/\1/p')"
    fi
    if [ "$os" = Linux ] && have systemctl; then
      ss_state=$(tm systemctl --user is-system-running 2>/dev/null | head -1)
      [ -n "$ss_state" ] && echo "systemd $ss_state"
    fi
  fi

  if has roots; then
    echo "@@roots"
    for cwd in "$@"; do
      top=$(cd "$cwd" 2>/dev/null && tm git rev-parse --show-toplevel 2>/dev/null)
      cdir=$(cd "$cwd" 2>/dev/null && tm git rev-parse --git-common-dir 2>/dev/null)
      if [ -n "$cdir" ]; then cdir=$(cd "$cwd" && cd "$cdir" 2>/dev/null && pwd -P); fi
      printf '%s\t%s\t%s\n' "$cwd" "${top:--}" "${cdir:--}"
    done
  fi

  # Listeners feed both `@@listeners` and the pid list for `@@pids`.
  if has listeners || has pids; then
    lkind=none; lout=
    if [ "$os" = Linux ] && have ss; then
      lkind=ss; lout=$(run listeners tm ss -ltnpH)
    elif have lsof; then
      lkind=lsof; lout=$(runq listeners tm lsof -nP -iTCP -sTCP:LISTEN -Fpcn)
    fi
    if has listeners; then
      if [ "$lkind" = none ]; then echo "@@listeners"; echo "@@absent ss"
      else echo "@@listeners $lkind"; [ -n "$lout" ] && printf '%s\n' "$lout"; fi
    fi
  fi

  if has pids; then
    if [ "$lkind" = ss ]; then
      lp=$(echo "$lout" | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -un | head -60 | tr '\n' ' ')
    else
      lp=$(echo "$lout" | sed -n 's/^p\([0-9][0-9]*\)$/\1/p' | sort -un | head -60 | tr '\n' ' ')
    fi
    if [ "$os" = Linux ]; then
      echo "@@pids"
      seen=" "
      for p in $lp; do
        pp=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
        for q in $p $pp; do
          [ "$q" -gt 0 ] 2>/dev/null || continue
          case "$seen" in *" $q "*) continue;; esac
          seen="$seen$q "
          emit_pid "$q"
        done
      done | grep -v '^@@'
    elif [ -n "$lp" ]; then
      plist=$(echo $lp | tr ' ' ',')
      parents=$(tm ps -o ppid= -p "$plist" 2>/dev/null | tr -d ' ' | grep -v -E '^(0|1)$' | sort -u | tr '\n' ',')
      all="$plist${parents:+,${parents%,}}"
      # BSD ps cuts a non-final comm column to 16 chars, so comm gets its own listing.
      echo "@@ps"; runq ps tm ps -ww -o pid=,ppid=,args= -p "$all" | cut -c1-400
      echo "@@psc"; runq psc tm ps -o pid=,comm= -p "$all"
      echo "@@lsofp"; runq lsofp tm lsof -a -d cwd,1 -p "$all" -Fpfn
    fi
  fi

  if has units; then
    echo "@@units"
    if [ "$os" = Linux ] && have systemctl; then
      run units tm systemctl --user list-units --type=service --all --no-pager --plain --no-legend
    fi
  fi

  if has files; then
    seen=" "
    for cwd in "$@"; do
      r=$(root_of "$cwd")
      case "$seen" in *" $r "*) continue;; esac
      seen="$seen$r "
      # A pane in $HOME or / must not make the whole tree "the project".
      case "$r" in /|"${HOME:-/}"|"${HOME:-/}"/) continue;; esac
      printf '@@files %s\n' "$r"
      run files find_files "$r"
    done
  fi

  # Only the names of port/URL-ish keys, never secret-looking ones and never values, from at
  # most six root-level env files.
  if has env; then
    seen=" "; ecount=0
    for cwd in "$@"; do
      r=$(root_of "$cwd")
      case "$seen" in *" $r "*) continue;; esac
      seen="$seen$r "
      case "$r" in /|"${HOME:-/}"|"${HOME:-/}"/) continue;; esac
      for f in .dev-lane.env .env .env.local .env.development .env.dev .env.hot; do
        [ "$ecount" -ge 6 ] && break
        [ -f "$r/$f" ] || continue
        ecount=$((ecount + 1))
        printf '@@env %s/%s\n' "$r" "$f"
        grep -n -E '^(export +)?[A-Za-z0-9_]*(PORT|URL|HOST|ORIGIN)[A-Za-z0-9_]*=' "$r/$f" 2>/dev/null \
          | sed -E 's/^([0-9]+):(export +)?([A-Za-z0-9_]*)=.*/\1:\3/' \
          | grep -v -i -E '^[0-9]+:.*(SECRET|TOKEN|KEY|PASS|CREDENTIAL)' | head -40
      done
    done
  fi

  # Docker last of the data sections: a wedged daemon costs its timeout once, and everything
  # above has already been printed by then.
  if has host || has compose || has containers; then
    dcr=1
    if have docker; then
      dv=$(tm docker version --format '{{.Server.Version}}' 2>"$errf"); dcr=$?
      if [ $dcr -eq 0 ]; then
        has host && { echo "@@host"; echo "docker $(printf '%s\n' "$dv" | grep -v '^$' | head -1 | cut -c1-300)"; }
      else
        de=$(grep -v -e '^$' -e '^@@' "$errf" 2>/dev/null | head -1 | cut -c1-300)
        has host && { echo "@@host"; echo "docker_error ${de:-exit $dcr}"; }
        echo "@@error docker"; errdetail
      fi
    fi
    if has compose; then
      echo "@@compose"
      if ! have docker; then echo "@@absent docker"
      elif [ $dcr -eq 0 ]; then run compose tm docker compose ls -a --format json; fi
    fi
    if has containers; then
      echo "@@containers"
      if ! have docker; then echo "@@absent docker"
      elif [ $dcr -eq 0 ]; then
        if cout=$(tm docker ps -a --no-trunc --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "com.docker.compose.project.config_files"}}' 2>"$errf"); then
          [ -n "$cout" ] && printf '%s\n' "$cout" | grep -v '^@@'
        else
          echo "@@error containers"; errdetail
        fi
      fi
    fi
  fi

  if has vms; then
    echo "@@vms parallels"
    if have prlctl; then run vms tm prlctl list -a -j; else echo "@@absent prlctl"; fi
    echo "@@vms vmpal"
    if have vmpal; then run vms tm vmpal list --json; else echo "@@absent vmpal"; fi
    echo "@@vms lima"
    if have limactl; then run vms tm limactl list --json; else echo "@@absent limactl"; fi
  fi

  echo "@@pp-end"
  n=$((n + 1))
  if [ "$frames" -gt 0 ] && [ "$n" -ge "$frames" ]; then break; fi
  sleep "$iv"
done
exit 0
"""#.replacingOccurrences(of: "PROTOCOL_VERSION", with: String(protocolVersion))

    /// `sh -c` argv: the script, `$0`, sections, interval, frame count, then the working directories.
    public static func shellArguments(sections: [String], cwds: [String], interval: Int = 15, frames: Int = 1) -> [String] {
        ["-c", source, "herdrm-project", sections.joined(separator: ","), String(interval), String(frames)] + cwds
    }

    /// The remote command string; the login shell may be fish or zsh, so the script
    /// runs under an explicit `/bin/sh` and every argument is quoted.
    public static func remoteCommand(sections: [String], cwds: [String], interval: Int = 15, frames: Int = 1) -> String {
        let arguments = [sections.joined(separator: ","), String(interval), String(frames)]
            .map(ShellQuoting.quoted) + cwds.map(ShellQuoting.quoted)
        return "exec /bin/sh -c \(ShellQuoting.quoted(source)) herdrm-project " + arguments.joined(separator: " ")
    }

    /// The probe is POSIX sh: Windows hosts and tailcat devices (no shell access) get none.
    public static func isSupported(_ device: Device) -> Bool {
        if device.isTailcat { return false }
        return device.osID?.lowercased() != "windows"
    }
}
