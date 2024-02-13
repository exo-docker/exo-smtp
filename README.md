# SMTP container

This container contains the basic configuration to send emails from other containers.

## Run the container
```
# docker run -d --name smtp exoplatform/smtp:latest
```
* You can map ```/var/spool/postfix``` to a volume if you want the queue to be persistent
* Logs are in the directory /var/log/mail and can be stored in a volume is needed

Link the containers you want to send mail from with this container :
```
  docker run -d --link smtp:smtp otherimage
```


### Available parameters

* ```RELAY_DOMAINS``` : if you want to specify the domains to relay emails to
* ```DEBUG``` : Activate the postfix debug logs 

## DKIM 

You can activate DKIM signature by using the following environment variables:

| Name                    | Type / Default value | Description   |
|-------------------------|----------------------|---------------|
| `DKIM_ENABLED`          | Boolean : `false`      | Enable DKIM Signature              |
| `DKIM_DOMAIN`           | String :`<mandatory>`| DKIM Domain name              |
| `DKIM_SELECTOR`         | String : `default`   | DKIM Selector              |
| `DKIM_AUTHORIZED_HOSTS` | String : `<optional>`| DKIM authorized sender hosts (comma seperated list)           |


* Authentication

You can activate authentication by using the following environment variables:

| Name                    | Type / Default value  | Description   |
|-------------------------|-----------------------|---------------|
| `AUTH_ENABLED`          | Boolean : `false`     | Enable Authentication              |
| `RELAY_HOST`            | String :`<mandatory>` | Relay Host             |
| `AUTH_USER    `         | String : `<mandatory>`| Auth username             |
| `AUTH_PASSWORD`         | String : `<optional>` | Auth password           |