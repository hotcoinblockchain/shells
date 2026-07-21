sudo tee /etc/apt/apt.conf.d/99force-confold >/dev/null <<'EOF'
Dpkg::Options {
  "--force-confdef";
  "--force-confold";
};
EOF

sudo env \
  DEBIAN_FRONTEND=noninteractive \
  UCF_FORCE_CONFFOLD=1 \
  NEEDRESTART_MODE=a \
  do-release-upgrade -f DistUpgradeViewNonInteractive


sudo rm -f /etc/apt/apt.conf.d/99force-confold
