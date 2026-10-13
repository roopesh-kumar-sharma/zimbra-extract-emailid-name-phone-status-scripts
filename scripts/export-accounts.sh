#!/usr/bin/env bash
# Export EmailID, Status, Name and Mobile for all mailboxes from LDAP to a CSV file.
#
# Usage (run as the zimbra / zextras user):
#   BASE=/opt/zimbra  ./export-accounts.sh     # Zimbra
#   BASE=/opt/zextras ./export-accounts.sh     # Carbonio
#
# Optional:
#   OUT=/path/to/file.csv                      # default: /tmp/mailbox_report.csv
#   NTFY_URL=https://ntfy.example.com/topic    # push notification when finished

set -o pipefail
umask 077

BASE="${BASE:-/opt/zimbra}"
OUT="${OUT:-/tmp/mailbox_report.csv}"
FILTER='(&(objectClass=zimbraAccount)(!(zimbraIsSystemResource=TRUE)))'

# Load LDAP URL, bind user and password from the local config
source "$BASE/bin/zmshutil"; zmsetvars

# Keep the password out of the process list
PWFILE=$(mktemp)
trap 'rm -f "$PWFILE"' EXIT
printf '%s' "$zimbra_ldap_password" > "$PWFILE"

"$BASE/common/bin/ldapsearch" -LLL -o ldif-wrap=no -x \
  -H "$ldap_master_url" -D "$zimbra_ldap_userdn" -y "$PWFILE" \
  -b "" "$FILTER" \
  mail displayName cn mobile zimbraAccountStatus \
| awk -v RS= -F'\n' '
BEGIN { print "EmailID,Status,Name,Mobile" }
{ m=mob=s=n=c=""
  for (i=1;i<=NF;i++) {
    if ($i ~ /^mail: /)                 m=substr($i,7)
    if ($i ~ /^mobile: /)               mob=substr($i,9)
    if ($i ~ /^zimbraAccountStatus: /)  s=substr($i,22)
    if ($i ~ /^displayName: /)          n=substr($i,14)
    if ($i ~ /^cn: /)                   c=substr($i,5)
  }
  print m "," s ",\"" (n ? n : c) "\"," mob
}' > "$OUT"
rc=$?

rows=$(( $(wc -l < "$OUT") - 1 ))
if [ "$rc" -eq 0 ] && [ "$rows" -gt 0 ]; then
  MSG="Export finished: $rows accounts -> $OUT"
else
  MSG="Export FAILED (rc=$rc, rows=$rows)"
fi
echo "$MSG"

if [ -n "${NTFY_URL:-}" ]; then
  curl -s -H "Title: Mailbox export" -d "$MSG" "$NTFY_URL" > /dev/null
fi

[ "$rc" -eq 0 ] && [ "$rows" -gt 0 ]
