{ config, lib, pkgs, ... }:

with lib;

let

  smbToString = x: if builtins.typeOf x == "bool"
                   then boolToString x
                   else toString x;

  cfg = config.services.samba;

  samba = cfg.package;

  setupScript =
    ''
      mkdir -p /var/lock/samba /var/log/samba /var/cache/samba /var/lib/samba/private
    '';

  configFile = pkgs.writeText "smb.conf"
    (if cfg.configText != null then cfg.configText else
    ''
      [global]
      security = ${cfg.securityType}
      passwd program = /run/wrappers/bin/passwd %u
      pam password change = ${smbToString cfg.syncPasswordsByPam}
      invalid users = ${smbToString cfg.invalidUsers}

      ${cfg.extraConfig}

      ${smbToString (map shareConfig (attrNames cfg.shares))}
    '');

  # This may include nss_ldap, needed for samba if it has to use ldap.
  nssModulesPath = config.system.nssModules.path;

  daemonService = appName: args:
    { description = "Samba Service Daemon ${appName}";

      requiredBy = [ "samba.target" ];
      partOf = [ "samba.target" ];

      environment = {
        LD_LIBRARY_PATH = nssModulesPath;
        LOCALE_ARCHIVE = "/run/current-system/sw/lib/locale/locale-archive";
      };

      serviceConfig = {
        ExecStart = "${samba}/sbin/${appName} ${args}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Type = "notify";
      };

      restartTriggers = [ configFile ];
    };

in

{

  ###### interface

  options = {

    services.samba-ad-dc = {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to enable Samba AD DC, which provides Samba Active Directory Domain Controller

          <note>
            <para>If you use the firewall consider adding the following:</para>
            <programlisting>
              networking.firewall.allowedTCPPorts = [ 139 445 ];
              networking.firewall.allowedUDPPorts = [ 137 138 ];
            </programlisting>
          </note>
        '';
      };

      useRfc2307 =  {
        type = types.bool;
        default = true;
        description = ''
          Whether to enable RFC3207 during provisioning, which enables you to store
          Unix attributes in AD, such as user IDs (UID), home directories paths, 
          group IDs (GID). Enabling the NIS extensions has no disadvantages. 
          However, enabling them in an existing domain requires manually extending the AD schema. 
        '';
      };

      realm = mkOption {
        type = types.str;
        example = "samdom.example.com";
        description = ''
          Used as the kerberos realm and the AD DNS domain.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.samba;
        defaultText = "pkgs.samba";
        example = literalExample "pkgs.samba3";
        description = ''
          Defines which package should be used for the samba server.
        '';
      };

      serverRole = mkOption {
        type = types.enum [ "dc" "member" "standalone"];
        default = "dc";
        description = ''
          Role of the installed server
        '';
      };

      adminPass = mkOption {
        type = types.str;
        default = "root";
        description = ''
          Password must meet complexity requirements, or provisioning fails.
          https://technet.microsoft.com/en-us/library/cc786468%28v=ws.10%29.aspx
        '';
      };
      
      dnsForwarderIpAddr = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "172.16.0.1";
        description = ''
          Forwarder if internal Samba DNS backend is used
        '';
      };

      dnsBackend = mkOption {
        type = types.enum [ "SAMBA_INTERNAL" "BIND9_DLZ" ];
        default = "SAMBA_INTERNAL";
        desription = ''
          DNS backend that will be used by the AD DC.
        '';
      };

      bindInterfaces = mkOption {
        type = types.nullOr types.listOf types.str;
        default = "null";
        example = "lo eth0";
        description = ''
          If the server has multiple interfaces, bind Samba to these concrete interfaces.
        '';
      };
      
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Additional global section and extra section lines go in here.
        '';
        example = ''
          guest account = nobody
          map to guest = bad user
        '';
      };

    };

  };


  ###### implementation

  config = mkMerge
    [ { assertions =
          [ { assertion = cfg.nsswins -> cfg.enableWinbindd;
              message   = "If samba.nsswins is enabled, then samba.enableWinbindd must also be enabled";
            }
          ];
        # Always provide a smb.conf to shut up programs like smbclient and smbspool.
        environment.etc = singleton
          { source =
              if cfg.enable then configFile
              else pkgs.writeText "smb-dummy.conf" "# Samba is disabled.";
            target = "samba/smb.conf";
          };
      }

      (mkIf cfg.enable {

        system.nssModules = optional cfg.nsswins samba;

        systemd = {
          targets.samba = {
            description = "Samba Server";
            requires = [ "samba-setup.service" ];
            after = [ "samba-setup.service" "network.target" ];
            wantedBy = [ "multi-user.target" ];
          };

          services = {
            "samba-smbd" = daemonService "smbd" "-F";
            "samba-nmbd" = mkIf cfg.enableNmbd (daemonService "nmbd" "-F");
            "samba-winbindd" = mkIf cfg.enableWinbindd (daemonService "winbindd" "-F");
            "samba-setup" = {
              description = "Samba Setup Task";
              script = setupScript;
              unitConfig.RequiresMountsFor = "/var/lib/samba";
            };
          };
        };

        security.pam.services.samba = {};

      })
    ];

}
