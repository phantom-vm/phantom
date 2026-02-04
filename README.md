## TODOs

I am going to build a macOS app that can run macOS virtual machine using cli tool

There're two parts: 
* The main app would serve as a daemon, which exposes the JSON API for VM creation, destory. And it should know avaiable images and running vm status. This repo is for that project. 
* Then we have a cli tool written in bun, which can call the JSON API for operations. Under `../phantom-cli` folder.

As an MVP, let's support these commands: 
  * `phantom image pull`: pulls image from Apple's website
  * `phantom image list`: shows available images
  * `phantom ps`: shows running VM
  * `phantom run IMAGE`: start a new VM using image
  * `phantom stop VM_ID`: stop a macOS VM
