# IIS Blue-Green Deploy

A shared github action to manage blue-green deploys under a single IIS server.

Right now it only exposes one action, but the underlying powershell would support exposing separate actions for creating the required environment, pushing code, swapping deploy slots, and more. 

One reason we might want to split out more actions is so that we can run more extensive testing on the site before taking it live without this library needing to get involved with the testing.

## Basic Deploy

```yml
- name: Deploy to IIS
  uses: WesternCapital/iis-blue-green/actions/deploy@v1-alpha
  with: 
    artifact-path: ./path/to/files-to-publish
    farm-name: webfarm-name
    host-name: subdomain.example.com # IMPORTANT: this should not include the protocol (i.e http://)
    blue-IISWebsiteName: sitename-blue
    blue-WebRootDirectory: "some/path/blue"
    blue-FarmServerName: "probably-same-as-slot-site-name"
    blue-Port: 3002
    green-IISWebsiteName: "probably-same-as-slot-site-name"
    green-WebRootDirectory: "some/path/green"
    green-FarmServerName: "sitename-green"
    green-Port: 3003
```