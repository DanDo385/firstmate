#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname helpers with no source-time side effects,
# so read-only callers can load them without any library's state setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# Assigns <output-variable> the root that holds per-task temp and launch
# directories: FM_TMP_ROOT, else the first non-blank, non-comment line of
# <config-dir>/tmp-root, else /tmp. A leading "~/" expands against this host's
# $HOME, so one inherited value lands in each host's own home. Returns 1, leaving
# the variable unset, for a value that is not an absolute path or that holds
# whitespace, because callers splice the root into unquoted shell lines.
fm_tmp_root_to() {  # <output-variable> <config-dir>
  local fm_root=${FM_TMP_ROOT:-} fm_line
  if [ -z "$fm_root" ] && [ -f "$2/tmp-root" ] && [ ! -L "$2/tmp-root" ]; then
    while IFS= read -r fm_line || [ -n "$fm_line" ]; do
      fm_line=${fm_line%"${fm_line##*[![:space:]]}"}
      fm_line=${fm_line#"${fm_line%%[![:space:]]*}"}
      case "$fm_line" in ''|'#'*) continue ;; esac
      fm_root=$fm_line
      break
    done < "$2/tmp-root"
  fi
  # shellcheck disable=SC2088 # a literal ~/ prefix from the config file, expanded here
  case "$fm_root" in '~/'*) fm_root=$HOME/${fm_root#\~/} ;; esac
  [ -n "$fm_root" ] || fm_root=/tmp
  case "$fm_root" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$fm_root" in *[[:space:]]*) return 1 ;; esac
  while [ "${fm_root%/}" != "$fm_root" ] && [ "$fm_root" != / ]; do fm_root=${fm_root%/}; done
  printf -v "$1" '%s' "$fm_root"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}
