#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

hr(){ printf '%*s\n' "${COLUMNS:-70}" '' | tr ' ' '─'; }
header(){ clear; echo -e "${BOLD}$1${RESET}"; hr; }
ask(){ local p="$1" d="${2:-}"; read -r -p "$p" v; echo "${v:-$d}"; }
ok(){ echo -e "${GREEN}✔${RESET} $*"; }
warn(){ echo -e "${YELLOW}⚠${RESET} $*"; }
err(){ echo -e "${RED}✖${RESET} $*"; }
pause(){ read -r -p "Press Enter to continue..." _; }
