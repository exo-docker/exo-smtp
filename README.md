# SMTP container

This container contains the basic configuration to send emails from other containers.

## Run the container
```
# docker run -d --name smtp exoplatform/smtp:latest
```
* You can map ```/var/spool/postfix``` to a volume if you want the queue to be persistent
* Logs are sent to **stdout** (visible via `docker logs`) AND to files in `/var/log/mail` (can be stored in a volume for persistence).

Link the containers you want to send mail from with this container :
```
  docker run -d --link smtp:smtp otherimage
```


### Available parameters

| Name | Type / Default value | Description |
|------|----------------------|-------------|
| `RELAY_DOMAINS` | String : `<optional>` | Domains to relay emails to (empty = all) |
| `MYNETWORKS` | String : `127.0.0.0/8 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8` | Authorized sender networks |
| `DEBUG` | Boolean : `false` | Activate the postfix debug logs |
| `PCONF_<param>` | Any | Set any Postfix parameter (e.g., `PCONF_message_size_limit=20480000`) |

## DKIM 

You can activate DKIM signature by using the following environment variables:

| Name                    | Type / Default value | Description   |
|-------------------------|----------------------|---------------|
| `DKIM_ENABLED`          | Boolean : `false`      | Enable DKIM Signature              |
| `DKIM_DOMAIN`           | String :`<mandatory>`| DKIM Domain name              |
| `DKIM_SELECTOR`         | String : `default`   | DKIM Selector              |
| `DKIM_AUTOGEN`          | Boolean : `false`    | Automatically generate DKIM key if missing |
| `DKIM_AUTHORIZED_HOSTS` | String : `<optional>`| DKIM authorized sender hosts (comma seperated list)           |


* Authentication

You can activate authentication by using the following environment variables:

| Name                    | Type / Default value  | Description   |
|-------------------------|-----------------------|---------------|
| `AUTH_ENABLED`          | Boolean : `false`     | Enable Authentication              |
| `RELAY_HOST`            | String :`<mandatory>` | Relay Host             |
| `AUTH_USER    `         | String : `<mandatory>`| Auth username             |
| `AUTH_PASSWORD`         | String : `<optional>` | Auth password           |
