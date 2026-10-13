# Zimbra & Carbonio Admin Scripts

Small, read-only scripts for administering Zimbra and Carbonio mail servers.

## Export mailbox accounts

`scripts/export-accounts.sh` exports every real mailbox to a CSV file in a few seconds.

| Column | Source | Notes |
|---|---|---|
| EmailID | `mail` | Primary address |
| Status | `zimbraAccountStatus` | active, closed, locked, lockout, maintenance, pending |
| Name | `displayName` | Falls back to `cn` if empty |
| Mobile | `mobile` | Blank if not set on the account |

System accounts (spam, ham, virus quarantine) are excluded.

### Requirements

- Zimbra or Carbonio server with local OpenLDAP
- Shell access as the `zimbra` user (Zimbra) or `zextras` user (Carbonio)
- `bash` and `awk` only. No Python needed.

### Usage

```bash
# Zimbra (run as zimbra)
BASE=/opt/zimbra ./scripts/export-accounts.sh

# Carbonio (run as zextras)
BASE=/opt/zextras ./scripts/export-accounts.sh
```

The CSV is written to `/tmp/mailbox_report.csv` with permissions `600`.

| Option | Purpose | Default |
|---|---|---|
| `BASE` | Install path | `/opt/zimbra` |
| `OUT` | Output file | `/tmp/mailbox_report.csv` |
| `NTFY_URL` | Send a push notification when finished | not set |

### Check the result

```bash
wc -l /tmp/mailbox_report.csv                              # accounts + 1 header line
awk -F, 'NR>1 && $NF!=""' /tmp/mailbox_report.csv | wc -l  # accounts with a mobile number
```

### How it works

Account data lives in OpenLDAP. The script loads the LDAP URL and credentials from the local Zimbra config, runs one `ldapsearch` for all non-system accounts, and formats the result as CSV with `awk`. This is much faster than looping `zmprov`, which starts a JVM for every call.

### Notes

- **Multi-master LDAP:** the script handles a space-separated list of masters. Run it once on any node.
- **Read-only:** `ldapsearch` cannot change any data.
- **Test first:** to try one account, change `FILTER` in the script to `(mail=user@example.com)`.

### Troubleshooting

| Problem | Fix |
|---|---|
| Output has only the header | Check you are running as `zimbra` / `zextras`. If it persists, set the base DN in place of `-b ""` (find it with `ldapsearch ... -s base namingContexts`) |
| `confidential (TLS/SSL) required` | Add `-ZZ` after `-x` in the script |
| Cannot write the CSV | An old file owned by another user exists. Delete it or set a different `OUT` |
| Mobile column mostly empty | The `mobile` attribute is not populated. Some sites use `telephoneNumber` |
| Name blank for some users | Non-ASCII names come back base64-encoded and need decoding |

## Security

- The CSV contains personal data. Delete it after use.

## License

MIT
