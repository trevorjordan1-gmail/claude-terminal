# shellcheck shell=bash
# ct-desc: LAB VMs ONLY — remove password complexity requirements (never included in --all-extras)

PWQ=/etc/security/pwquality.conf

if [ -f "$PWQ" ] && [ ! -f "$PWQ.claude-terminal.bak" ]; then
    sudo cp -a "$PWQ" "$PWQ.claude-terminal.bak" || fail "could not back up $PWQ"
fi

sudo tee "$PWQ" >/dev/null <<'EOF' || fail "could not write $PWQ"
# Written by claude-terminal --with-weak-passwords (lab-VM policy: any password
# allowed). Original config saved as pwquality.conf.claude-terminal.bak —
# restore it to revert.
minlen = 1
dcredit = 0
ucredit = 0
lcredit = 0
ocredit = 0
minclass = 0
maxrepeat = 0
maxsequence = 0
gecoscheck = 0
dictcheck = 0
usercheck = 0
enforcing = 0
EOF

# The reference machines additionally remove the root-guard line from
# /etc/pam.d/gdm-password (allows root at the GDM greeter). That is riskier,
# so this module only tells you how instead of doing it:
next_step "Optional (manual, riskier): to allow root login at the GDM greeter, remove the 'pam_succeed_if.so user != root' line from /etc/pam.d/gdm-password."
ok "password quality checks disabled (backup: $PWQ.claude-terminal.bak)"
