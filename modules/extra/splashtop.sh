# shellcheck shell=bash
# ct-desc: Splashtop Streamer — MANUAL for now (prints instructions; automation is a planned follow-up)

cat <<'EOF'

  Splashtop Streamer is not automated yet (their .deb comes from a
  version-specific download page). Manual steps:

    1. Download the Ubuntu .deb:
         https://www.splashtop.com/downloads#streamer   (Ubuntu 64-bit)
    2. Install it:
         sudo apt-get install -y ./Splashtop_Streamer_Ubuntu_*.deb
    3. Launch "Splashtop Streamer" from the app grid, log in to your
       Splashtop account, and grant it autostart when asked.

EOF

next_step "Splashtop: manual install for now — steps were printed above (also in README)."
skip "manual install for now"
