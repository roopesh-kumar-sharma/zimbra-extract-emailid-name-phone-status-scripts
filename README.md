# Zimbra & Carbonio Admin Scripts

Practical, production-tested scripts and notes for administering **Zimbra Collaboration Suite** and **Zextras Carbonio** mail servers.

> Tested on: Carbonio 24.9.1 and Zimbra (OpenLDAP, multi-master replication).
> All commands are **read-only** unless stated otherwise.

## Contents

- [Export mailbox accounts to CSV](#export-mailbox-accounts-to-csv)
  - [How it works](#how-it-works)
  - [Quick start](#quick-start)
  - [Reusable script](#reusable-script)
  - [Multi-master (MMR) LDAP](#multi-master-mmr-ldap)
  - [Optional: push notification with ntfy](#optional-push-notification-with-ntfy)
  - [Troubleshooting](#troubleshooting)
- [zmprov alternative](#zmprov-alternative)
- [Security notes](#security-notes)

---

## Export mailbox accounts to CSV

Exports the following fields for every real mailbox (system accounts excluded):

| CSV column | LDAP attribute | Notes |
|---|---|---|
| EmailID | `mail` | Primary address |
| Status | `zimbraAccountStatus` | `active`, `closed`, `locked`, `lockout`, `maintenance`, `pending` |
| Name | `displayName` | Falls back to `cn` when `displayName` is empty |
| Mobile | `mobile` | Blank if not populated on the account |

### How it works

Zimbra and Carbonio store account data in **OpenLDAP**, not MySQL. `zmprov` is a wrapper that reads that directory and starts a JVM on every call, which is slow for bulk work. Querying LDAP directly with `ldapsearch` returns every account in a single query and finishes in seconds.

| Component | Purpose |
|---|---|
| `source .../bin/zmshutil; zmsetvars` | Loads Zimbra's local config into shell variables (`$ldap_master_url`, `$zimbra_ldap_userdn`, `$zimbra_ldap_password`) so no credentials are typed or copied |
| `-x` | Simple bind authentication |
| `-H` | LDAP server URL(s) |
| `-D` / `-w` | Bind DN and password |
| `-b ""` | Search base (empty = search the whole directory) |
| `-LLL` | Plain LDIF output, no comments or version header |
| `-o ldif-wrap=no` | Prevents long values being split across lines |
| Filter `(&(objectClass=zimbraAccount)(!(zimbraIsSystemResource=TRUE)))` | All accounts **AND NOT** system mailboxes (spam, ham, virus quarantine, etc.) |
| `awk -v RS= -F'\n'` | Treats each blank-line-separated LDIF block as one record and each line as one field |

### Quick start

Run as the service user: `zimbra` on Zimbra, `zextras` on Carbonio. Replace the path accordingly.

```bash
BASE=/opt/zimbra        # Carbonio: /opt/zextras

source $BASE/bin/zmshutil; zmsetvars

$BASE/common/bin/ldapsearch -LLL -o ldif-wrap=no -x \
  -H "$ldap_master_url" -D "$zimbra_ldap_userdn" -w "$zimbra_ldap_password" \
  -b "" '(&(objectClass=zimbraAccount)(!(zimbraIsSystemResource=TRUE)))' \
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
}' > /tmp/mailbox_report.csv

chmod 600 /tmp/mailbox_report.csv
wc -l /tmp/mailbox_report.csv
head -5 /tmp/mailbox_report.csv
```

**Always test on a single account first.** Replace the filter with:

```bash
'(mail=user@example.com)'
```

and compare the row with `zmprov -l ga user@example.com mail displayName cn mobile zimbraAccountStatus`.

> **Shell note:** keep the filter in **single quotes**. Inside double quotes, interactive bash expands `!` as history and fails with `event not found`.

### Reusable script

Save as `scripts/export-accounts.sh` and run as the `zimbra` / `zextras` user.

```bash
#!/usr/bin/env bash
# export-accounts.sh
# Export EmailID, Status, Name, Mobile from Zimbra/Carbonio LDAP to CSV.
#
# Usage:
#   BASE=/opt/zimbra  ./export-accounts.sh        # Zimbra
#   BASE=/opt/zextras ./export-accounts.sh        # Carbonio
#   NTFY_URL=https://ntfy.example.com/my-topic ./export-accounts.sh   # optional push notification

set -o pipefail
umask 077

BASE="${BASE:-/opt/zimbra}"
OUT="${OUT:-/tmp/mailbox_report.csv}"
FILTER='(&(objectClass=zimbraAccount)(!(zimbraIsSystemResource=TRUE)))'

source "$BASE/bin/zmshutil"; zmsetvars

# Keep the LDAP password out of the process list
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
  MSG="LDAP export finished: $rows accounts"
else
  MSG="LDAP export FAILED (rc=$rc, rows=$rows)"
fi
echo "$MSG"

if [ -n "${NTFY_URL:-}" ]; then
  curl -s -H "Title: Zimbra export" -d "$MSG" "$NTFY_URL" > /dev/null
fi

[ "$rc" -eq 0 ] && [ "$rows" -gt 0 ]
```

Make it executable with `chmod 750 scripts/export-accounts.sh`.

### Multi-master (MMR) LDAP

With MMR replication, `ldap_master_url` contains several URLs separated by spaces:

```
ldap://ldap1.example.local:389 ldap://ldap2.example.local:389
```

- **Always quote it:** `-H "$ldap_master_url"`. Unquoted, the shell splits it into separate arguments and ldapsearch fails with `Could not parse LDAP URI(s)=-D`.
- OpenLDAP tries the URLs in order, so you get failover if the first master is down.
- **Run the export once.** All masters replicate the same data, so one node returns the full list.
- If a URI error persists, pin to the first master:
  ```bash
  ldap_master_url=$(echo "$ldap_master_url" | awk '{print $1}')
  ```

### Optional: push notification with ntfy

For long-running exports, send a notification when the job finishes. The script above does this when `NTFY_URL` is set.

```bash
curl -s -H "Title: Zimbra export" -d "LDAP export finished" https://ntfy.example.com/my-topic
```

- On the public `ntfy.sh` service, **topics are readable by anyone who knows the name**. Use a long random topic name, or self-host ntfy.
- Send only counts or status. Never put account data in the message.
- For a self-hosted instance with authentication, add `-H "Authorization: Bearer <token>"`.
- LDAP nodes are often on isolated networks, so confirm outbound access first.

### Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Could not parse LDAP URI(s)=-D` | `$ldap_master_url` is empty (variables not loaded, or running as the wrong user) | Run as `zimbra` / `zextras` and run `zmsetvars` in the same shell |
| `-bash: !: event not found` | History expansion on `!` inside double quotes | Put the filter in single quotes |
| `-bash: -H: command not found` | A `#` at the start of the first line commented out the command | Remove the `#` and paste the full block |
| Output file contains only the header | Search returned nothing (wrong base DN, or the command failed) | Find the base DN with `ldapsearch -x -H "$ldap_master_url" -D "$zimbra_ldap_userdn" -w "$zimbra_ldap_password" -s base -b "" namingContexts` and use it in place of `-b ""` |
| `confidential (TLS/SSL) required` | LDAP requires an encrypted connection | Add `-ZZ` after `-x` (add `LDAPTLS_REQCERT=never` in front for a local query with a self-signed certificate) |
| `Permission denied` writing the CSV | An old file owned by another user (for example `root`) | Remove it or use a different `OUT` path |
| Mobile column is mostly empty | The `mobile` attribute is not populated | Check with `zmprov -l ga user@example.com mobile telephoneNumber`. Some sites store numbers in `telephoneNumber` |
| Name column is blank for some accounts | Non-ASCII names are returned base64-encoded as `displayName::` | Count them with `... displayName \| grep -c '^displayName::'`. If non-zero, the awk needs a base64 decode step |

**Verify the result**

```bash
wc -l /tmp/mailbox_report.csv                                   # accounts + 1 header
awk -F, 'NR>1 && $NF!=""' /tmp/mailbox_report.csv | wc -l       # accounts with a mobile number
```

---

## zmprov alternative

Fine for a single account or a quick check. Slow for bulk work.

```bash
# Zimbra
zmprov -l ga user@example.com | grep -E "^(cn|displayName|mail|mobile|zimbraAccountStatus):"

# Carbonio
carbonio prov -l ga user@example.com | grep -E "^(cn|displayName|mail|mobile|zimbraAccountStatus):"
```

Anchor the pattern with `^`. A bare `mail:` also matches attributes such as `zimbraMobilePolicyAllowConsumerEmail:`, and an empty alternative (`a||b`) matches every line.

Admin console: **Manage → Accounts** can download a CSV, but it only includes the displayed columns and normally not `mobile`. Use LDAP for a complete export.

---

## Security notes

- Exports contain personal data (names, mobile numbers). Create files with `umask 077` or `chmod 600`, and delete them once delivered.
- `-w` exposes the LDAP password in `ps` for the duration of the command. Use `-y <passwordfile>` on shared servers, as the reusable script does.
- `ldapsearch` is read-only. It cannot change LDAP or Zimbra data.
- Never commit real hostnames, client names, credentials or exported CSV files to this repository. Add `*.csv` to `.gitignore`.

## Suggested repository layout

```
.
├── README.md
├── .gitignore
└── scripts/
    └── export-accounts.sh
```

## License

MIT
