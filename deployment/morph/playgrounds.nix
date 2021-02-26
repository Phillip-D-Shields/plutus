{
  mkInstance = { defaultMachine, plutus-playground, marlowe-playground, pkgs, ports, machines, ... }:
    hostName:
    let
      promNodeTextfileDir = pkgs.writeTextDir "roles.prom"
        ''
          machine_role{role="playgrounds"} 1
        '';
      plutusPlayground = "${plutus-playground.server-invoker}/bin/plutus-playground";
      marlowePlayground = "${marlowe-playground.server-invoker}/bin/marlowe-playground";
      playgroundServiceConfig = {
        TimeoutStartSec = "0";
        Restart = "always";
        DynamicUser = true;
        StateDirectory = [ "pab" ];
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectKernelModules = true;
        PrivateDevices = true;
        SystemCallArchitectures = "native";
        ConfigurationDirectory = "playground";
      };

    in
    { config, pkgs, lib, ... }:
    {
      deployment.secrets = {
        "plutus-secrets" = {
          source = "./secrets.plutus.${machines.environment}.json";
          destination = "/etc/playground/secrets.plutus.${machines.environment}.json";
          permissions = "0644"; # FIXME: this seems like a bad idea
          action = [ "systemctl" "restart" "plutus-playground" ];
        };
      };
      imports = [ (defaultMachine hostName pkgs) ];

      networking.firewall = {
        enable = true;
        allowedTCPPorts = with ports; [ ssh plutus-playground-webserver nodeExporter ];
      };


      systemd.services.plutus-playground = {
        enable = true;
        after = [ "network.target" ];
        wantedBy = [ "nginx.service" ];
        before = [ "nginx.service" ];
        serviceConfig = playgroundServiceConfig;
        script = "${plutusPlayground} --config=/etc/playground/secrets.plutus.${machines.environment}.json webserver -p 4000";
      };

      systemd.services.marlowe-playground = {
        enable = true;
        after = [ "network.target" ];
        wantedBy = [ "nginx.service" ];
        before = [ "nginx.service" ];
        serviceConfig = playgroundServiceConfig;
        script = "${marlowePlayground} webserver -p 4001";
      };

      services.nginx = {
        enable = true;

        recommendedGzipSettings = true;
        recommendedProxySettings = true;
        recommendedOptimisation = true;

        appendHttpConfig = ''
          limit_req_zone $binary_remote_addr zone=plutuslimit:10m rate=1r/s;
          server_names_hash_bucket_size 128;
          log_format compression '$remote_addr - $remote_user [$time_local] '
          '"$request" $status $body_bytes_sent '
          '"$http_referer" "$http_user_agent" "$gzip_ratio"';
        '';

        upstreams.plutus-playground.servers."127.0.0.1:4000" = { };
        upstreams.marlowe-playground.servers."127.0.0.1:4001" = { };

        virtualHosts = {
          "plutus-playground" = {
            listen = [{ addr = "0.0.0.0"; port = 8080; }];
            locations = {
              "/" = {
                root = "${plutus-playground.client}";
                extraConfig = ''
                  # we want to rate limit the API however the webpage loading downloads a few files so we allow a small burst
                  limit_req zone=plutuslimit burst=10;
                  add_header 'Cache-Control' 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0';
                  expires off;
                '';
              };
              "@fallback" = {
                proxyPass = "http://plutus-playground";
                proxyWebsockets = true;
              };
            };
          };
          "marlowe-playground" = {
            listen = [{ addr = "0.0.0.0"; port = 9080; }];
            locations = {
              "/" = {
                root = "${marlowe-playground.client}";
                extraConfig = ''
                  # we want to rate limit the API however the webpage loading downloads a few files so we allow a small burst
                  limit_req zone=plutuslimit burst=10;
                  add_header 'Cache-Control' 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0';
                  expires off;
                  error_page 404 = @fallback;
                '';
              };
              "@fallback" = {
                proxyPass = "http://marlowe-playground";
                proxyWebsockets = true;
              };
            };
          };
        };
      };

    };
}
