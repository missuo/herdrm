#if os(macOS)
import Foundation

/// The POSIX sh sampler behind the machine stats under the terminal. It runs once per
/// watched device (locally, or as one long-lived `ssh` command) and prints a
/// frame per tick, so polling never opens a new connection. When HerdrM goes
/// away the pipe closes and the next write's SIGPIPE ends the remote loop.
///
/// Arguments: `$1` interval in seconds, `$2` frame count (0 = forever).
/// On Linux the header also carries `agentcg <used> <limit>`: herdr's cgroup (anon +
/// kernel memory of every pane against its `memory.max`), when herdr runs under a cap.
/// Frame: `@@hm-begin`, `key value` header lines, then `@@procs` / `@@args` /
/// `@@vm` / `@@df` sections, then `@@hm-end` — see `MachineStatsParser`.
/// Command lines are sent only where the executable name doesn't say enough:
/// interpreters (node, bun, deno, python), whose script names the agent; Claude
/// Code's versioned binary (`…/claude/versions/2.1.289`); the tmux servers
/// holding agent-team teammates (`tmux -L claude-swarm-<lead pid>`); and anything
/// mentioning MCP, so `MCPServerMatcher` can name each server (`graft mcp`,
/// `npm exec @playwright/mcp`). Full `args` for every process would make each
/// frame several times larger.
enum MachineStatsScript {
    static let source = #"""
PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
LC_ALL=C; export LC_ALL
iv=${1:-2}; frames=${2:-0}
os=$(uname -s); host=$(hostname 2>/dev/null); n=0
want='$2 ~ /(^|\/)(node|bun|deno|python[0-9.]*)$/ || $2 ~ /\/claude\/versions\// || /claude-swarm-[0-9]/ || /[Mm][Cc][Pp]|modelcontextprotocol/'
while :; do
  echo "@@hm-begin"
  echo "os $os"; echo "host $host"; echo "self $$"
  if [ "$os" = Linux ]; then
    echo "tck $(getconf CLK_TCK)"; echo "page $(getconf PAGESIZE)"; echo "ncpu $(getconf _NPROCESSORS_ONLN)"
    read up _ < /proc/uptime; echo "uptime $up"
    read l1 l5 l15 _ < /proc/loadavg; echo "load $l1 $l5 $l15"
    read c rest < /proc/stat; echo "cpu $rest"
    while read k v _; do
      case $k in MemTotal:|MemAvailable:|MemFree:|Buffers:|Cached:|SwapTotal:|SwapFree:) echo "mem ${k%:} $v";; esac
    done < /proc/meminfo
    # Only our own herdr: on a shared host another user's server has its own cap.
    hp=
    for p in $(ps -eo pid=,args= | awk '$2 ~ /(^|\/)herdr$/ && $3 == "server" {print $1}'); do
      if [ -O "/proc/$p" ]; then hp=$p; break; fi
    done
    if [ -n "$hp" ]; then
      cg=$(sed -n 's/^0:://p' "/proc/$hp/cgroup" 2>/dev/null)
      if [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.max" ]; then
        mx=$(cat "/sys/fs/cgroup$cg/memory.max")
        if [ "$mx" != max ]; then
          used=$(awk '$1=="anon"||$1=="kernel"{s+=$2} END{print s+0}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null)
          echo "agentcg ${used:-0} $mx"
        fi
      fi
    fi
    echo "@@procs"
    cat /proc/[0-9]*/stat 2>/dev/null | awk '{c=$0; sub(/^[0-9]+ \(/,"",c); sub(/\) [^)]*$/,"",c); s=$0; sub(/.*\) /,"",s); split(s,a," "); print $1, a[2], a[12]+a[13], a[20], a[22], c}'
    echo "@@args"; ps -eo pid=,args= | awk "$want" | cut -c1-300
  else
    echo "ncpu $(sysctl -n hw.ncpu)"; echo "memsize $(sysctl -n hw.memsize)"
    echo "now $(date +%s)"; echo "boottime $(sysctl -n kern.boottime)"
    echo "load $(sysctl -n vm.loadavg)"; echo "swap $(sysctl -n vm.swapusage)"
    echo "@@vm"; vm_stat
    echo "@@procs"
    ps -Ao pid=,ppid=,rss=,time=,comm= | awk '{c=$0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9:.-]+ /,"",c); k=split(c,p,"/"); print $1, $2, $3, $4, p[k]}'
    echo "@@args"; ps -Ao pid=,args= | awk "$want" | cut -c1-300
  fi
  echo "@@df"; df -Pk / "$HOME" 2>/dev/null
  echo "@@hm-end"
  n=$((n + 1))
  if [ "$frames" -gt 0 ] && [ "$n" -ge "$frames" ]; then exit 0; fi
  # The first delta comes quickly so the meters fill in right away.
  if [ "$n" -eq 1 ]; then sleep 1; else sleep "$iv"; fi
done
"""#

    /// `sh -c` argv: the script, `$0`, then its arguments.
    static func shellArguments(interval: Int, frames: Int = 0) -> [String] {
        ["-c", source, "herdrm-stats", String(interval), String(frames)]
    }

    /// The remote command string; the login shell may be fish or zsh, so the
    /// script runs under an explicit `/bin/sh`.
    static func remoteCommand(interval: Int, frames: Int = 0) -> String {
        "exec /bin/sh -c \(ShellQuoting.quoted(source)) herdrm-stats \(interval) \(frames)"
    }
}
#endif
