#
# @summary manages a wireguard setup
#
# @param interface the title of the defined resource, will be used for the wg interface
# @param input_interface ethernet interface where the wireguard packages will enter the system, used for firewall rules
# @param manage_firewall if true, a ferm rule will be created
# @param dport destination for firewall rules / where our wg instance will listen on. defaults to the last digits from the title
# @param source_addresses an array of ip addresses from where we receive wireguard connections
# @param destination_addresses array of addresses where the remote peer connects to (our local ips), used for firewalling
# @param public_key base64 encoded pubkey from the remote peer
# @param endpoint fqdn:port or ip:port where we connect to
# @param addresses different addresses for the systemd-networkd configuration
# @param persistent_keepalive is set to 1 or greater, that's the interval in seconds wireguard sends a keepalive to the other peer(s). Useful if the sender is behind a NAT gateway or has a dynamic ip address
# @param description an optional string that will be added to the wireguard network interface
# @param mtu configure the MTU (maximum transision unit) for the wireguard tunnel. By default linux will figure this out. You might need to lower it if you're connection through a DSL line. MTU needs to be equal on both tunnel endpoints
# @param peers is an array of struct (Wireguard::Peers) for multiple peers
# @param routes different routes for the systemd-networkd configuration
# @param private_key Define private key which should be used for this interface, if not provided a private key will be generated
# @param preshared_key Define preshared key which should be used for this interface
#
# @author Tim Meusel <tim@bastelfreak.de>
# @author Sebastian Rakel <sebastian@devunit.eu>
#
# @see https://www.freedesktop.org/software/systemd/man/systemd.netdev.html#%5BWireGuardPeer%5D%20Section%20Options
#
# @example Peer with one node and setup dualstack firewall rules
#  wireguard::interface {'as2273':
#    source_addresses => ['2003:4f8:c17:4cf::1', '149.9.255.4'],
#    public_key       => 'BcxLll1BVxGQ5DeijroesjroiesjrjvX+EBhS4vcDn0R0=',
#    endpoint         => 'wg.example.com:53668',
#    addresses        => [{'Address' => '192.168.123.6/30',},{'Address' => 'fe80::beef:1/64'},],
#  }
#
# @example Peer with one node and setup dualstack firewall rules with peers in a different layer2
#  wireguard::interface {'as2273':
#    source_addresses => ['2003:4f8:c17:4cf::1', '149.9.255.4'],
#    public_key       => 'BcxLll1BVxGQ5DeijroesjroiesjrjvX+EBhS4vcDn0R0=',
#    endpoint         => 'wg.example.com:53668',
#    addresses        => [{'Address' => '192.168.218.87/32', 'Peer' => '172.20.53.97/32'}, {'Address' => 'fe80::ade1/64',},],
#  }
#
# @example Create a passive wireguard interface that listens for incoming connections. Useful when the other side has a dynamic IP / is behind NAT
#  wireguard::interface {'as2273':
#    source_addresses => ['2003:4f8:c17:4cf::1', '149.9.255.4'],
#    public_key       => 'BcxLll1BVxGQ5DeijroesjroiesjrjvX+EBhS4vcDn0R0=',
#    dport            => 53668,
#    addresses        => [{'Address' => '192.168.218.87/32', 'Peer' => '172.20.53.97/32'}, {'Address' => 'fe80::ade1/64',},],
#  }
#
# @example create a wireguard interface behind a DSL line with changing IP with lowered MTU
#  wireguard::interface {'as3668-2':
#    source_addresses      => ['144.76.249.220', '2a01:4f8:171:1152::12'],
#    public_key            => 'Tci/bHoPCjTpYv8bw17xQ7P4OdqzGpEN+NDueNjUvBA=',
#    preshared_key         => '/22q9I+RpWRsU+zshW8skv1p00TvnEE6fTvPJuI2Cp4=',
#    endpoint              => 'router02.bastelfreak.org:1338',
#    dport                 => 1338,
#    input_interface       => $facts['networking']['primary'],
#    addresses             => [{'Address' => '169.254.0.10/32', 'Peer' =>'169.254.0.9/32'},{'Address' => 'fe80::beef:f/64'},],
#    destination_addresses => [],
#    persistent_keepalive  => 5,
#    mtu                   => 1412,
# }
#
# @example create a wireguard interface with multiple peers
#  wireguard::interface { 'wg0':
#    dport     => 1338,
#    addresses => [{'Address' => '192.0.2.1/24'}],
#    peers     => [
#      {
#         public_key  => 'foo==',
#         allowed_ips => ['192.0.2.2'],
#      },
#      {
#         public_key  => 'bar==',
#         allowed_ips => ['192.0.2.3'],
#      }
#    ],
#  }
#
define wireguard::interface (
  Wireguard::Peers $peers = [],
  Optional[String[1]] $endpoint = undef,
  Integer[0, 65535] $persistent_keepalive = 0,
  Array[Stdlib::IP::Address] $destination_addresses = [$facts['networking']['ip'], $facts['networking']['ip6'],],
  String[1] $interface = $title,
  Integer[1024, 65000] $dport = Integer(regsubst($title, '^\D+(\d+)$', '\1')),
  String[1] $input_interface = $facts['networking']['primary'],
  Boolean $manage_firewall = true,
  Array[Stdlib::IP::Address] $source_addresses = [],
  Array[Hash[String,Variant[Stdlib::IP::Address::V4::CIDR,Stdlib::IP::Address::V6::CIDR]]] $addresses = [],
  Optional[String[1]] $description = undef,
  Optional[Integer[1280, 9000]] $mtu = undef,
  Optional[String[1]] $public_key = undef,
  Array[Hash[String[1], Variant[String[1], Boolean]]] $routes = [],
  Optional[String[1]] $private_key = undef,
  Optional[String[1]] $preshared_key = undef,
) {
  require wireguard

  if empty($peers) and !$public_key {
    fail('peers or public_key have to been set')
  }

  if $manage_firewall {
    $daddr = empty($destination_addresses) ? {
      true    => undef,
      default => $destination_addresses,
    }
    ferm::rule { "allow_wg_${interface}":
      action    => 'ACCEPT',
      chain     => 'INPUT',
      proto     => 'udp',
      dport     => $dport,
      interface => $input_interface,
      saddr     => $source_addresses,
      daddr     => $daddr,
      notify    => Service['systemd-networkd'],
    }
  }

  $private_key_path = "${wireguard::config_directory}/${interface}"

  if $private_key {
    file { $private_key_path:
      ensure  => 'file',
      content => $private_key,
      owner   => 'root',
      group   => 'systemd-network',
      mode    => '0640',
      notify  => Exec["generate public key ${interface}"],
    }
  } else {
    exec { "generate private key ${interface}":
      command => "wg genkey > ${interface}",
      cwd     => $wireguard::config_directory,
      creates => $private_key_path,
      path    => '/usr/bin',
      before  => File[$private_key_path],
      notify  => Exec["generate public key ${interface}"],
    }

    file { $private_key_path:
      ensure => 'file',
      owner  => 'root',
      group  => 'systemd-network',
      mode   => '0640',
    }
  }

  exec { "generate public key ${interface}":
    command => "wg pubkey < ${interface} > ${interface}.pub",
    cwd     => $wireguard::config_directory,
    creates => "${wireguard::config_directory}/${interface}.pub",
    path    => '/usr/bin',
  }

  file { "${wireguard::config_directory}/${interface}.pub":
    ensure  => 'file',
    owner   => 'root',
    group   => 'root',
    mode    => '0600',
    require => Exec["generate public key ${interface}"],
  }

  if $public_key {
    $peer = [{
        public_key => $public_key,
        endpoint   => $endpoint,
    }]
  } else {
    $peer = []
  }

  systemd::network { "${interface}.netdev":
    content         => epp("${module_name}/netdev.epp", {
        'interface'     => $interface,
        'dport'         => $dport,
        'description'   => $description,
        'preshared_key' => $preshared_key,
        'mtu'           => $mtu,
        'peers'         => $peers + $peer,
    }),
    restart_service => true,
    owner           => 'root',
    group           => 'systemd-network',
    mode            => '0440',
    require         => File["/etc/wireguard/${interface}"],
  }

  $network_epp_params = {
    'interface' => $interface,
    'addresses' => $addresses,
    'routes'    => $routes,
  }

  systemd::network { "${interface}.network":
    content         => epp("${module_name}/network.epp", $network_epp_params),
    restart_service => true,
    owner           => 'root',
    group           => 'systemd-network',
    mode            => '0440',
  }
}
