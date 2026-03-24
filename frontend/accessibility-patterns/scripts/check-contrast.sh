#!/usr/bin/env bash
# ============================================================================
# check-contrast.sh — Color contrast ratio checker
#
# Usage:
#   ./check-contrast.sh <foreground> <background>
#   ./check-contrast.sh "#333333" "#ffffff"
#   ./check-contrast.sh 333 fff
#   ./check-contrast.sh "rgb(51,51,51)" "#ffffff"
#
# Calculates the contrast ratio per WCAG 2.x algorithm and reports
# pass/fail for AA and AAA levels for both normal and large text.
#
# Requirements: bash 4+ (or zsh), bc
# ============================================================================

set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

usage() {
  echo "Usage: $0 <foreground-color> <background-color>"
  echo ""
  echo "Color formats supported:"
  echo "  Hex:  #333333, #333, 333333, 333"
  echo "  RGB:  rgb(51,51,51)"
  echo ""
  echo "Examples:"
  echo "  $0 '#333333' '#ffffff'"
  echo "  $0 333 fff"
  echo "  $0 '#1a1a2e' '#e0e0e0'"
  exit 1
}

if [[ $# -lt 2 ]]; then
  usage
fi

FG_INPUT="$1"
BG_INPUT="$2"

# --- Parse color to R G B (0-255) ---
parse_color() {
  local input="$1"
  # Remove # prefix, whitespace
  input="${input#\#}"
  input="${input// /}"

  # Handle rgb(r,g,b)
  if [[ "$input" =~ ^rgb\(([0-9]+),([0-9]+),([0-9]+)\)$ ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
    return
  fi

  # Handle 3-char hex
  if [[ ${#input} -eq 3 ]]; then
    local r="${input:0:1}" g="${input:1:1}" b="${input:2:1}"
    input="${r}${r}${g}${g}${b}${b}"
  fi

  # Handle 6-char hex
  if [[ ${#input} -eq 6 && "$input" =~ ^[0-9a-fA-F]{6}$ ]]; then
    local r=$((16#${input:0:2}))
    local g=$((16#${input:2:2}))
    local b=$((16#${input:4:2}))
    echo "$r $g $b"
    return
  fi

  echo -e "${RED}Error: Invalid color format: $1${NC}" >&2
  echo "Supported: #hex, hex, rgb(r,g,b)" >&2
  exit 1
}

# --- Calculate relative luminance (WCAG 2.x formula) ---
# L = 0.2126 * R_lin + 0.7152 * G_lin + 0.0722 * B_lin
# where R_lin = (R/255 <= 0.04045) ? R/255/12.92 : ((R/255 + 0.055)/1.055)^2.4
linearize() {
  local val="$1"
  # bc doesn't have a power function with fractional exponents built in,
  # so we use the natural log/exp approach: a^b = e^(b*ln(a))
  bc -l <<EOF
scale=10
srgb = $val / 255
if (srgb <= 0.04045) {
  srgb / 12.92
} else {
  e(2.4 * l((srgb + 0.055) / 1.055))
}
EOF
}

luminance() {
  local r="$1" g="$2" b="$3"
  local r_lin g_lin b_lin
  r_lin=$(linearize "$r")
  g_lin=$(linearize "$g")
  b_lin=$(linearize "$b")

  bc -l <<EOF
scale=10
0.2126 * $r_lin + 0.7152 * $g_lin + 0.0722 * $b_lin
EOF
}

# --- Calculate contrast ratio ---
contrast_ratio() {
  local l1="$1" l2="$2"
  bc -l <<EOF
scale=4
lighter = $l1
darker = $l2
if ($l2 > $l1) {
  lighter = $l2
  darker = $l1
}
(lighter + 0.05) / (darker + 0.05)
EOF
}

# --- Parse colors ---
read -r fg_r fg_g fg_b <<< "$(parse_color "$FG_INPUT")"
read -r bg_r bg_g bg_b <<< "$(parse_color "$BG_INPUT")"

# --- Calculate luminance ---
fg_lum=$(luminance "$fg_r" "$fg_g" "$fg_b")
bg_lum=$(luminance "$bg_r" "$bg_g" "$bg_b")

# --- Calculate ratio ---
ratio=$(contrast_ratio "$fg_lum" "$bg_lum")

# --- Round to 2 decimal places ---
ratio_display=$(printf "%.2f" "$ratio")

# --- Determine pass/fail ---
pass_fail() {
  local ratio="$1" threshold="$2"
  local result
  result=$(bc -l <<< "$ratio >= $threshold")
  if [[ "$result" == "1" ]]; then
    echo -e "${GREEN}PASS${NC}"
  else
    echo -e "${RED}FAIL${NC}"
  fi
}

aa_normal=$(pass_fail "$ratio" "4.5")
aa_large=$(pass_fail "$ratio" "3.0")
aaa_normal=$(pass_fail "$ratio" "7.0")
aaa_large=$(pass_fail "$ratio" "4.5")

# --- Color preview (ANSI approximate) ---
fg_hex=$(printf "%02x%02x%02x" "$fg_r" "$fg_g" "$fg_b")
bg_hex=$(printf "%02x%02x%02x" "$bg_r" "$bg_g" "$bg_b")

# --- Output ---
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Color Contrast Checker (WCAG 2.x)${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Foreground: ${BOLD}#${fg_hex}${NC}  (rgb ${fg_r}, ${fg_g}, ${fg_b})"
echo -e "  Background: ${BOLD}#${bg_hex}${NC}  (rgb ${bg_r}, ${bg_g}, ${bg_b})"
echo ""
echo -e "  ${BOLD}Contrast Ratio: ${ratio_display}:1${NC}"
echo ""
echo -e "${BOLD}  ┌──────────────────┬──────────────┬──────────────┐${NC}"
echo -e "${BOLD}  │                  │  Normal Text │  Large Text  │${NC}"
echo -e "${BOLD}  │                  │  (< 18pt)    │  (≥ 18pt or  │${NC}"
echo -e "${BOLD}  │                  │              │   ≥ 14pt bold)│${NC}"
echo -e "${BOLD}  ├──────────────────┼──────────────┼──────────────┤${NC}"
echo -e "${BOLD}  │${NC}  WCAG AA (≥4.5:1) │  ${aa_normal}         │  ${aa_large}         ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  (Standard)       │  need 4.5:1  │  need 3:1    ${BOLD}│${NC}"
echo -e "${BOLD}  ├──────────────────┼──────────────┼──────────────┤${NC}"
echo -e "${BOLD}  │${NC}  WCAG AAA (≥7:1)  │  ${aaa_normal}         │  ${aaa_large}         ${BOLD}│${NC}"
echo -e "${BOLD}  │${NC}  (Enhanced)       │  need 7:1    │  need 4.5:1  ${BOLD}│${NC}"
echo -e "${BOLD}  └──────────────────┴──────────────┴──────────────┘${NC}"
echo ""
echo -e "  ${BLUE}WCAG 1.4.3${NC}  Contrast (Minimum) — Level AA"
echo -e "  ${BLUE}WCAG 1.4.6${NC}  Contrast (Enhanced) — Level AAA"
echo -e "  ${BLUE}WCAG 1.4.11${NC} Non-text Contrast — ≥ 3:1 for UI components"
echo ""

# --- Non-text contrast ---
ui_result=$(pass_fail "$ratio" "3.0")
echo -e "  UI Component Contrast (≥ 3:1): ${ui_result} — WCAG 1.4.11"
echo ""

# --- Exit code based on AA normal text ---
aa_pass=$(bc -l <<< "$ratio >= 4.5")
if [[ "$aa_pass" == "1" ]]; then
  echo -e "  ${GREEN}${BOLD}✅ Passes WCAG AA for normal text${NC}"
  exit 0
else
  echo -e "  ${RED}${BOLD}❌ Fails WCAG AA for normal text${NC}"
  echo -e "  ${YELLOW}Suggestion: Darken the foreground or lighten the background${NC}"
  exit 1
fi
