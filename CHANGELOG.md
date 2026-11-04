# Changelog

## [1.13.6](https://github.com/Gyang91/ha-airprint/compare/v1.13.5...v1.13.6) (2026-11-04)


### Bug Fixes

* a sleeping printer that misses one mDNS browse stays Online ([92d28f5](https://github.com/Gyang91/ha-airprint/commit/92d28f55966ac3db9d75ccd2587283887f2b1a68))

## [1.13.5](https://github.com/Gyang91/ha-airprint/compare/v1.13.4...v1.13.5) (2026-11-04)


### Performance

* see print jobs within 30 s and restart when a service dies ([294a40b](https://github.com/Gyang91/ha-airprint/commit/294a40bd11f091676f852a2c3be530de8cc18eee))

## [1.13.4](https://github.com/Gyang91/ha-airprint/compare/v1.13.3...v1.13.4) (2026-11-04)


### Bug Fixes

* a configured printer that is switching off is not a new printer ([638c4f8](https://github.com/Gyang91/ha-airprint/commit/638c4f8c4e163b157df5e881a30a39800ae2a093))

## [1.13.3](https://github.com/Gyang91/ha-airprint/compare/v1.13.2...v1.13.3) (2026-11-04)


### Bug Fixes

* never offer the add-on's own AirPrint queue as a new printer ([c42e52e](https://github.com/Gyang91/ha-airprint/commit/c42e52eb268daf55d5bf0ceeb1e6af12b6e91136))

## [1.13.2](https://github.com/Gyang91/ha-airprint/compare/v1.13.1...v1.13.2) (2026-11-04)


### Bug Fixes

* keep jobs for a switched-off printer waiting for 20 minutes ([c512bba](https://github.com/Gyang91/ha-airprint/commit/c512bba1263900b4cdaa66f0bb39fcc57b8a07da))

## [1.13.1](https://github.com/Gyang91/ha-airprint/compare/v1.13.0...v1.13.1) (2026-11-04)


### Documentation

* GHCR package inherits the repository's public visibility ([7701693](https://github.com/Gyang91/ha-airprint/commit/77016936b3ce06abadbf97f1f41a6d9ec754525c))

## [1.13.0](https://github.com/Gyang91/ha-airprint/compare/v1.12.0...v1.13.0) (2026-11-04)


### Features

* a driver belongs to the printer that needs it ([de5c0ea](https://github.com/Gyang91/ha-airprint/commit/de5c0ea290b69a631c30810b9bd284bd7afa6d5b))
* a Status sensor that says what is wrong ([70303e8](https://github.com/Gyang91/ha-airprint/commit/70303e8bf2d043c81d37a04df0f279444ad96d2c))
* add-on icon and logo ([4ae31ad](https://github.com/Gyang91/ha-airprint/commit/4ae31ad12003018852be40e32a1c98a70ca685e7))
* AirPrint bridge add-on for Home Assistant ([be7edc6](https://github.com/Gyang91/ha-airprint/commit/be7edc66d91e35f063a845d5e080236d4709733f))
* ask for a driver when a printer has none ([7581e9e](https://github.com/Gyang91/ha-airprint/commit/7581e9e5aa3940a550ff659cf919be7c4e5a05c4))
* brand icons for the integration ([00c7e09](https://github.com/Gyang91/ha-airprint/commit/00c7e09b0f381df363b2c85eae621797834c9702))
* bundle the free drivers, match them automatically, and read the printer over SNMP ([985ce47](https://github.com/Gyang91/ha-airprint/commit/985ce47cac20004973f734d3592c4b4bf5b7d93e))
* clearing the name restores the one we discovered ([3b23ff1](https://github.com/Gyang91/ha-airprint/commit/3b23ff1d6c7f8fcd288ba2d47a2c8ee45836b615))
* companion integration, so printers are real devices in Home Assistant ([4e3fe5d](https://github.com/Gyang91/ha-airprint/commit/4e3fe5de78929c9bad0680d12aac650110ab1bf4))
* configure printers from the integration, not add-on options ([9766dab](https://github.com/Gyang91/ha-airprint/commit/9766dab50db96e27af5f3ee540ec019f8ffcd887))
* configure the printer straight from the discovery card ([8de1774](https://github.com/Gyang91/ha-airprint/commit/8de1774b5ebb12c9742111e343a1d56ebfc5dc7c))
* driverless printing (IPP Everywhere) when no bundled driver matches ([30b1dae](https://github.com/Gyang91/ha-airprint/commit/30b1dae95e320824075c0db355bf3ba517e47049))
* drivers are installed at runtime, not baked into the image ([4481cdc](https://github.com/Gyang91/ha-airprint/commit/4481cdca3f5d0ba4b29a650b3097cac3d08ac6de))
* edit an existing printer ([889372e](https://github.com/Gyang91/ha-airprint/commit/889372edac20333ebec75e4c8d7be839354f8116))
* emoji picker for the printer name ([9a706fa](https://github.com/Gyang91/ha-airprint/commit/9a706fac37d4e84b8fd4721ea7836f83a2b8a770))
* friendly labels and help text for the config options ([e769432](https://github.com/Gyang91/ha-airprint/commit/e7694323feb0f12b7ee3664585340d29757a63c5))
* identify printers by Bonjour name, not IP address ([dd456ed](https://github.com/Gyang91/ha-airprint/commit/dd456ed660e37d6b103196aebf2bcf197ec1762d))
* pick an icon from the list, or paste in any emoji ([09ddffa](https://github.com/Gyang91/ha-airprint/commit/09ddffabfe85ab81681f811131471acda730ff56))
* prefill the printer's name and address from discovery ([37a9d0c](https://github.com/Gyang91/ha-airprint/commit/37a9d0c114ac35f0a079bc602f6a7d9b13c94094))
* printer_name is the name shown in AirPrint ([3b836ec](https://github.com/Gyang91/ha-airprint/commit/3b836eca15373e63e30a66341f0fc4af703aefb4))
* printers are config subentries ([6d88007](https://github.com/Gyang91/ha-airprint/commit/6d880078a0187933d7ceb55c831a6cdb90383551))
* remove drivers that are no longer listed; make the README generic ([27a78f7](https://github.com/Gyang91/ha-airprint/commit/27a78f70461b6acb5d579472ffbac0041329d48c))
* report printer status and new printers to Home Assistant ([df65f8c](https://github.com/Gyang91/ha-airprint/commit/df65f8c8897df613cc7e948746b1def8da126e6e))
* separate the printer's row in Home Assistant from the name it prints under ([9665bb7](https://github.com/Gyang91/ha-airprint/commit/9665bb7fcf6cb772c7bfe6522146de83def73b90))
* show the default name under the Name field ([802a78f](https://github.com/Gyang91/ha-airprint/commit/802a78f1435d9c8e5d99498d0ec69e72cc21a941))
* show the icon with the printer's name in Home Assistant ([2eaa9f1](https://github.com/Gyang91/ha-airprint/commit/2eaa9f189ff7a45b3369ff0a25c6cdb1458cca78))
* show the icon with the printer's name, and keep names from colliding ([e665bbb](https://github.com/Gyang91/ha-airprint/commit/e665bbbf913b6bcc4e3e9b293a66692f44d4ab86))
* support multiple printers, and find them on the network ([4f36d49](https://github.com/Gyang91/ha-airprint/commit/4f36d49a4b5e627485a51b5b613c0c0617f8ef29))
* the device defaults to the make and model ([cb5b26a](https://github.com/Gyang91/ha-airprint/commit/cb5b26acf6131d2803593a3930376cf1d0fc2d1d))
* the icon is a fixed list ([2b10d9b](https://github.com/Gyang91/ha-airprint/commit/2b10d9bf88eb8ba5e61cd531559d8e099d23601e))
* the icon must be one from the list ([7f93dde](https://github.com/Gyang91/ha-airprint/commit/7f93ddebc9b4c95dd04bb45bf682f6f5685216b0))
* update readme and settings with blog article link ([18d2c25](https://github.com/Gyang91/ha-airprint/commit/18d2c252140761f80fc70b4b9084b7effdfa1f41))


### Bug Fixes

* advertise only on the LAN ([cf73c81](https://github.com/Gyang91/ha-airprint/commit/cf73c812d19d13e1b1cfabe79d0e402fb75462a4))
* allow emoji in the printer name ([05cc554](https://github.com/Gyang91/ha-airprint/commit/05cc554f675a315d94b1b404b19842527d267068))
* broadcast printers as "@ home-assistant", not "@ airprint" ([7e8eaed](https://github.com/Gyang91/ha-airprint/commit/7e8eaedb3b0cd4002552e6f6bc614ce8f878cbdb))
* build driverless PPDs with cups-filters and print them over IPP ([c394699](https://github.com/Gyang91/ha-airprint/commit/c39469908ea8571f16f83dcf89df9c27cb3d179f))
* clear the device name Home Assistant copies from the row title ([a0e1e5d](https://github.com/Gyang91/ha-airprint/commit/a0e1e5d51e2478605f912f85a68e3deac2a4a55e))
* clearing the name never falls back to the device URI ([b41da48](https://github.com/Gyang91/ha-airprint/commit/b41da48b4cee5096f8ccd0f104d2131a325b4f52))
* discover printers over mDNS only, never the CUPS snmp backend ([af5771f](https://github.com/Gyang91/ha-airprint/commit/af5771f97fd31930c49cf2b316f8f797264d76ce))
* do not leave entities unavailable while the add-on restarts ([f3520b4](https://github.com/Gyang91/ha-airprint/commit/f3520b4db5a6a3d853aafe50006d758f93bbc97b))
* give each sensor its own icon ([753fe4b](https://github.com/Gyang91/ha-airprint/commit/753fe4b55bd839a4a7a7ea9a10e9129875a50360))
* let Location and Icon be cleared ([f4aa218](https://github.com/Gyang91/ha-airprint/commit/f4aa218880ef960f733d29bc9849ef8340142f94))
* make the displayed printer name configurable ([d536e29](https://github.com/Gyang91/ha-airprint/commit/d536e292c4db3fc7d05914873aa9e3c08b0d5a97))
* probe printer liveness over SNMP, not a raw 9100 connection ([a13c235](https://github.com/Gyang91/ha-airprint/commit/a13c235168f9f61745dbe9ef6228cdd9f0364403))
* renaming a printer no longer creates a second one ([316a5d7](https://github.com/Gyang91/ha-airprint/commit/316a5d71f110c9957d197878c35e22bd9344f2a0))
* resolve printers whose Bonjour name contains spaces ([b8e8749](https://github.com/Gyang91/ha-airprint/commit/b8e8749033142210bcbad61c9e3385b668da804c))
* retitle printer rows that were named after the printer ([b7cc24e](https://github.com/Gyang91/ha-airprint/commit/b7cc24ef2c7ba3e676cbb44c22e52a7d9a284bf2))
* retry driver matching and queue creation from the monitor loop ([9b42c27](https://github.com/Gyang91/ha-airprint/commit/9b42c27e33685e8c7a72a3463bd7e64406a374a5))
* saving a printer no longer wipes the driver list ([c3c1b7c](https://github.com/Gyang91/ha-airprint/commit/c3c1b7c82f9c1511430b971241feee2de53e52cd))
* say 'Printer updated' instead of the raw reconfigure_successful key ([aab01ab](https://github.com/Gyang91/ha-airprint/commit/aab01ab491ae8a6c19f1cd3753705212504b3de5))
* stay running with no printers configured ([2aa415c](https://github.com/Gyang91/ha-airprint/commit/2aa415ce9df7a52d30989190afc4182ea18e2425))
* the Add printer form explains itself ([9b540ba](https://github.com/Gyang91/ha-airprint/commit/9b540ba8b6d31277b6a4b696d81b8454bd25d046))
* the default name is the make and model ([9147caa](https://github.com/Gyang91/ha-airprint/commit/9147caad2696157697cc20f4cae571c5fd562fbd))
* the printer row is 'Printer', the device keeps the printer's name ([8325649](https://github.com/Gyang91/ha-airprint/commit/83256499c340ff349a60a4b577c3d171687580b6))
* the row carries the printer's name, the device is just 'Printer' ([ad47b42](https://github.com/Gyang91/ha-airprint/commit/ad47b428238a237f256ebb6a72bd229e90766943))


### Documentation

* capture architecture, status/discovery model, HA access & traps in CLAUDE.md ([5bf039f](https://github.com/Gyang91/ha-airprint/commit/5bf039f300a4076d97c879c0be74aa91d9f6707d))
* rewrite the README for a public repo ([9d0df35](https://github.com/Gyang91/ha-airprint/commit/9d0df3531908c8074e4be7ba05afeb7ed56408fb))
* the add-on is pulled, not compiled ([ce56049](https://github.com/Gyang91/ha-airprint/commit/ce56049143c7a0655b2cb681b0640580f037b549))
* write the README for the person setting up their printer ([1c2dcda](https://github.com/Gyang91/ha-airprint/commit/1c2dcdac2877bcb7b1889ad2fe4de3f6b5c3ad79))


### Code Refactoring

* drop the address option ([e1be20c](https://github.com/Gyang91/ha-airprint/commit/e1be20ce228ea1b760112c9db48e1857a1df0a5c))
* drop the global drivers option ([f8aaa9e](https://github.com/Gyang91/ha-airprint/commit/f8aaa9e4c5e427bdeced4880387a099374ed3ec5))
* drop the printer_icon option, always serve the bundled icon ([b2c0bf9](https://github.com/Gyang91/ha-airprint/commit/b2c0bf9e08059cd607a48ec0148b58e97cb5e9d8))
* keep the emoji as its own field ([2a1d293](https://github.com/Gyang91/ha-airprint/commit/2a1d2931b8381a5a6f7f9c68cb0c3bd85360efb4))
* one name per printer, the way Home Assistant does it ([6f04d65](https://github.com/Gyang91/ha-airprint/commit/6f04d6590332c2a8c6f185fc4928aa3c1cf90b4a))
* plain Name and Icon labels ([3a69eff](https://github.com/Gyang91/ha-airprint/commit/3a69effb0925f91db199a3e7f2eb0e22f6bc10c0))
* rename add-on to AirPrint, aligning with the repo ([87636d9](https://github.com/Gyang91/ha-airprint/commit/87636d953c684cb35118fa1b29dcd9e856d3a779))
* the field is called icon ([05cd429](https://github.com/Gyang91/ha-airprint/commit/05cd4298836faaaca5e11b752ab6d0c0da25e0d3))
