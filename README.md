# SMTP container

A small Postfix relay (with optional OpenDKIM signing, authenticated relay and TLS) to send emails from other containers.

## Run the container

```yaml
# docker-compose.yml
services:
  smtp:
    image: exoplatform/smtp:latest
    restart: unless-stopped
    volumes:
      - smtp-queue:/var/spool/postfix   # persistent queue (optional)
      - smtp-logs:/var/log/mail         # persistent logs (optional)
  app:
    image: otherimage
    environment:
      SMTP_HOST: smtp      # reachable by service name on the compose network
volumes:
  smtp-queue:
  smtp-logs:
```

Or with plain Docker (use a user-defined network; `--link` is deprecated):
```
docker network create mail
docker run -d --name smtp --network mail exoplatform/smtp:latest
docker run -d --network mail otherimage      # reach it at host "smtp", port 25
```

* The postfix user/group is uid/gid `1000`; make mounted volumes writable for it.
* Logs go to `/var/log/mail` **and** to stdout (`docker logs smtp`).
* The container stops if postfix, rsyslog or (when enabled) opendkim exits, so use a restart policy.

### General parameters

| Name | Default | Description |
|------|---------|-------------|
| `RELAY_DOMAINS` | *(empty)* | Extra domains to relay mail to |
| `MYNETWORKS` | `127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` | Clients allowed to relay **through** the container. Keep it to private ranges: never expose port 25 publicly with a wide value (open relay) |
| `MYHOSTNAME` | `hostname -f` | Postfix `myhostname` |
| `SMTP_HELO_NAME` | `$myhostname` | HELO name used on outgoing connections |
| `SMTPD_BANNER` | `$myhostname ESMTP` | SMTP banner |
| `MESSAGE_SIZE_LIMIT` | `10240000` | Max message size in bytes |
| `MAX_QUEUE_LIFETIME` | `5d` | How long undeliverable mail stays queued |
| `SMTP_FROM` | *(unset)* | Rewrite every envelope and header sender to this address (relays requiring a fixed From: SES, Office365…) |
| `LOG_TO_STDOUT` | `true` | Also log mail to stdout |
| `LOG_FILE_MODE` | `0640` | Permissions of files in `/var/log/mail` (use `0644` if another container reads them) |
| `DEBUG` | `false` | Postfix `smtpd -v` debug logs |

## DKIM

| Name                    | Type / Default value  | Description |
|-------------------------|-----------------------|-------------|
| `DKIM_ENABLED`          | Boolean : `false`     | Enable DKIM signature |
| `DKIM_DOMAIN`           | String : `<mandatory>`| Domain(s) to sign for, comma separated |
| `DKIM_SELECTOR`         | String : `default`    | DKIM selector (same for all domains) |
| `DKIM_AUTHORIZED_HOSTS` | String : `<optional>` | Hosts/networks whose mail is signed, comma separated (loopback is always included) |
| `DKIM_AUTOGENERATE`     | Boolean : `false`     | Generate a 2048-bit key if none exists and print the DNS TXT record in the logs |

Keys are read from `/etc/opendkim/keys/<domain>/<selector>.private`; mount them
(read-only is fine) or persist `/etc/opendkim/keys` when using `DKIM_AUTOGENERATE`.
Configuration is regenerated on every start, so changed variables take effect on restart.

## Authenticated relay

| Name            | Type / Default value  | Description |
|-----------------|-----------------------|-------------|
| `AUTH_ENABLED`  | Boolean : `false`     | Enable authentication to the relay |
| `RELAY_HOST`    | String : `<mandatory>`| Relay host |
| `RELAY_PORT`    | Integer : `<optional>`| Relay port (e.g. `587`) |
| `AUTH_USER`     | String : `<mandatory>`| Username |
| `AUTH_PASSWORD` | String : `<optional>` | Password (a warning is logged if empty) |

## Outbound TLS (encryption in transit)

| Name                      | Type / Default value | Description |
|---------------------------|----------------------|-------------|
| `SMTP_TLS_SECURITY_LEVEL` | `none`, `may`, `encrypt`, `verify`, `secure` : `may` (`encrypt` if `AUTH_ENABLED=true`) | `may` = opportunistic, `encrypt` = mandatory TLS, `verify`/`secure` = mandatory TLS with certificate validation |
| `SMTP_TLS_LOGLEVEL`       | Integer : `1`        | Postfix TLS log verbosity (0-4) |

## Inbound TLS (optional)

Mount a certificate and key to let clients use STARTTLS:

| Name                       | Default | Description |
|----------------------------|---------|-------------|
| `SMTPD_TLS_CERT_FILE`      | *(unset)* | Path to the certificate (PEM) |
| `SMTPD_TLS_KEY_FILE`       | *(unset)* | Path to the private key (PEM) |
| `SMTPD_TLS_SECURITY_LEVEL` | `may`   | `may` or `encrypt` |

Without them, inbound connections are not encrypted.

## Operations

```
docker exec smtp postqueue -p        # show the queue
docker exec smtp postqueue -f        # flush the queue
docker exec smtp postconf -n         # effective configuration
```

For metrics, run a [postfix_exporter](https://github.com/kumina/postfix_exporter) sidecar reading
the `smtp-logs` volume (set `LOG_FILE_MODE=0644` so it can read the files).

### Hardening notes

* Never publish port 25 to the internet; keep `MYNETWORKS` tight.
* Postfix needs root at startup to drop privileges; a locked-down run such as
  `--read-only --tmpfs /run --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE --cap-add=FOWNER --cap-add=KILL --cap-add=NET_BIND_SERVICE`
  is a good starting point but is **not validated** by the test suite: test it for your setup.

## Development

```
docker build -t exo-smtp:test .
./tests/smoke.sh exo-smtp:test
```
CI runs shellcheck, hadolint, the smoke test and a Trivy scan on every pull request.
