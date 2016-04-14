# SMTP container

This container contains the basic configuration to send emails from other containers.

## Run the container
```
# docker run -d --name smtp exoplatform/smtp:latest
```
* You can map ```/var/spool/postfix``` to a volume if you want the queue to be persistent

Link the containers you want to send mail from with this container :
```
  docker run -d --link smtp:smtp otherimage
```


### Available parameters

* ```RELAY_DOMAINS``` : if you want to specify the domains to relay emails to
* ```DEBUG``` : Activate the postfix debug logs 

## TODO

* Authentication
