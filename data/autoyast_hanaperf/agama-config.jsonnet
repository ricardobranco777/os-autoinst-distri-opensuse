{
  user: {
    fullName: 'Bernhard M. Wiedemann',
    password: '$6$vYbbuJ9WMriFxGHY$gQ7shLw9ZBsRcPgo6/8KmfDvQ/lCqxW8/WnMoLCoWGdHO6Touush1nhegYfdBbXRpsQuy/FTZZeg7gQL50IbA/',
    hashedPassword: true,
    userName: 'bernhard',
  },
  root: {
    password: '$6$vYbbuJ9WMriFxGHY$gQ7shLw9ZBsRcPgo6/8KmfDvQ/lCqxW8/WnMoLCoWGdHO6Touush1nhegYfdBbXRpsQuy/FTZZeg7gQL50IbA/',
    hashedPassword: true,
    sshPublicKey: 'enable ssh',
  },
  software: {
    patterns: ['sles_sap_HADB', 'sles_sap_HAAPP', 'sles_sap_DB', 'sles_sap_APP'],
  },
  product: {
    id: '{{AGAMA_PRODUCT_ID}}',
    registrationCode: '{{SCC_REGCODE_SLES4SAP}}',
  },
  storage: {
    drives: [
      {
        search: '/dev/disk/by-id/{{OSDISK}}',
        partitions: [
          { search: '*', delete: true },
          { generate: 'default' },
        ],
      },
    ],
  },
  network: {
    connections: [
      {
        id: 'Wired Connection',
        method4: 'auto',
        method6: 'auto',
        ignoreAutoDns: false,
        status: 'up',
      },
    ],
  },
  localization: {
    language: 'en_US.UTF-8',
    keyboard: 'us',
    timezone: 'Asia/Shanghai',
  },
  scripts: {
    pre: [
      {
        name: 'wipefs',
        content: |||
          #!/usr/bin/env bash
          for i in `lsblk -n -l -o NAME -d -e 7,11,254`
              do wipefs -af /dev/$i
              sleep 1
              sync
          done
        |||,
      },
    ],
    post: [
      {
        name: 'enable root login',
        chroot: true,
        content: |||
          #!/usr/bin/env bash
          echo 'PermitRootLogin yes' > /etc/ssh/sshd_config.d/root.conf
          # Workaround for bsc#1235024 NetworkManager to make sure the expected NIC up only
          rm -f /etc/NetworkManager/system-connections/default_connection.nmconnection
          rm -f /etc/NetworkManager/system-connections/Wired*nmconnection
          echo -e "[main]\nno-auto-default=type:ethernet" > /etc/NetworkManager/conf.d/disable_auto.conf
          echo -e "[connection]\nid=nic0\nuuid=$(uuidgen)\ntype=ethernet\n[ethernet]\nmac-address={{SUT_NETDEVICE}}\n[ipv4]\nmethod=auto\n" > /etc/NetworkManager/system-connections/nic0.nmconnection
          chmod 0600 /etc/NetworkManager/system-connections/nic0.nmconnection
        |||,
      },
    ],
  },
}
