# 1.1.1 (2023-06-28 10:27)

### Features

* Added group invitation sending
* Added webhook configuration per event in the individual instance registration

### Fixed

* Adjust dockerfile variables
* Fixed baileys version in package.json
* Fixed problem that did not validate if the token passed in create instance already existed
* Fixed problem that does not delete instance files in server mode

# 1.1.0 (2023-06-21 11:17)

### Features

* Improved fetch instances endpoint, now it also fetch other instances even if they are not connected
* Added conversion of audios for sending recorded audio, now it is possible to send mp3 audios and not just ogg
* Route to fetch all groups that the connection is part of
* Route to fetch all privacy settings
* Route to update the privacy settings
* Route to update group subject
* Route to update group description
* Route to accept invite code
* Added configuration of events by webhook of instances
* Now the api key can be exposed in fetch instances if the EXPOSE_IN_FETCH_INSTANCES variable is set to true
* Added option to generate qrcode as soon as the instance is created
* The created instance token can now also be optionally defined manually in the creation endpoint
* Route to send Sticker

### Fixed

* Adjust dockerfile variables
* tweaks in docker-compose to pass variables
* Adjust the route getProfileBusiness to fetchProfileBusiness
* fix error after logout and try to get status or to connect again
* fix sending narrated audio on whatsapp android and ios
* fixed the problem of not disabling the global webhook by the variable
* Adjustment in the recording of temporary files and periodic cleaning
* Fix for container mode also work only with files
* Remove recording of old messages on sync

# 1.0.9 (2023-06-10)

### Fixed

* Adjust dockerfile variables

# 1.0.8 (2023-06-09)

### Features

* Added Docker compose file
* Added ChangeLog file

# 1.0.7 (2023-06-08)

### Features

* Ghost mention
* Mention in reply
* Profile photo change
* Profile name change
* Profile status change
* Sending a poll
* Creation of LinkPreview if message contains URL
* New webhooks system, which can be separated into a url per event
* Sending the local webhook url as destination in the webhook data for webhook redirection
* Startup modes, server or container
* Server Mode works normally as everyone is used to
* Container mode made to use one instance per container, when starting the application an instance is already created and the qrcode is generated and it starts sending webhook without having to call it manually, it only allows one instance at a time.