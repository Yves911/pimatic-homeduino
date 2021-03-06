module.exports = (env) ->

  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'
  _ = env.require('lodash')
  homeduino = require('homeduino')

  Board = homeduino.Board

  class HomeduinoPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      @board = new Board(@config.serialDevice, @config.baudrate)

      @board.on("data", (data) ->
        env.logger.debug("data: \"#{data}\"")
      )

      @board.on("rfReceive", (event) -> 
        env.logger.debug 'received:', event.pulseLengths, event.pulses
      )

      @board.on("rf", (event) -> 
        env.logger.debug "#{event.protocol}: ", event.values
      )

      @pendingConnect = @board.connect().then( =>
        env.logger.info("Connected to homeduino device.")
        if @config.enableReceiving?
          @board.rfControlStartReceiving(@config.receiverPin).then( =>
            env.logger.debug("Receiving on pin #{@config.receiverPin}")
          ).catch( (err) =>
            env.logger.error("Couldn't start receiving: #{err.message}.")
          )
        return
      ).catch( (err) =>
        env.logger.error("Couldn't connect to homeduino device: #{err.message}.")
      )

      deviceConfigDef = require("./device-config-schema")

      deviceClasses = [
        HomeduinoDHTSensor,
        HomeduinoRFSwitch,
        HomeduinoRFTemperature,
        HomeduinoRFPir
      ]

      for Cl in deviceClasses
        do (Cl) =>
          @framework.deviceManager.registerDeviceClass(Cl.name, {
            configDef: deviceConfigDef[Cl.name]
            createCallback: (deviceConfig) => 
              device = new Cl(deviceConfig, @board, @config)
              return device
          })

  # Homed controls FS20 devices
  class HomeduinoDHTSensor extends env.devices.TemperatureSensor

    attributes:
      temperature:
        description: "the messured temperature"
        type: "number"
        unit: '°C'
      humidity:
        description: "the messured humidity"
        type: "number"
        unit: '%'


    constructor: (@config, @board) ->
      @id = config.id
      @name = config.name
      super()

      setInterval(( => 
        @_readSensor().then( (result) =>
          @emit 'temperature', result.temperature
          @emit 'humidity', result.humidity
        ).catch( (err) =>
          env.logger.error("Error reading DHT Sensor: #{err.message}.")
        )
      ), @config.interval)
    
    _readSensor: (attempt = 0)-> 
      # Already reading? return the reading promise
      if @_pendingRead? then return @_pendingRead
      # Don't read the sensor to frequently, the minimal reading interal should be 2.5 seconds
      if @_lastReadResult?
        now = new Date().getTime()
        if (now - @_lastReadTime) < 2000
          return Promise.resolve @_lastReadResult
      @_pendingRead = @board.whenReady().then( =>
        return @board.readDHT(@config.type, @config.pin).then( (result) =>
          @_lastReadResult = result
          @_lastReadTime = (new Date()).getTime()
          @_pendingRead = null
          return result
        )
      ).catch( (err) =>
        @_pendingRead = null
        if (err.message is "checksum_error" or err.message is "timeout_error") and attempt < 5
          env.logger.debug "got #{err.message} while reading dht sensor, retrying: #{attempt} of 5"
          return Promise.delay(2500).then( => @_readSensor(attempt+1) )
        else
          throw err
      )
      
    getTemperature: -> @_readSensor().then( (result) -> result.temperature )
    getHumidity: -> @_readSensor().then( (result) -> result.humidity )

  class HomeduinoRFSwitch extends env.devices.PowerSwitch

    constructor: (@config, @board, @_pluginConfig) ->
      @id = config.id
      @name = config.name

      @_protocol = Board.getRfProtocol(@config.protocol)
      unless @_protocol?
        throw new Error("Could not find a protocol with the name \"#{@config.protocol}\".")
      unless @_protocol.type is "switch"
        throw new Error("\"#{@config.protocol}\" is not a switch protocol.")

      @board.on('rf', (event) =>
        match = no
        if event.protocol is @config.protocol
          match = yes
          for optName, optValue of @config.protocolOptions
            #console.log "check", optName, optValue, event.values[optName]
            if event.values[optName] isnt optValue
              match = no
        @_setState(event.values.state) if match
      )
      super()

    changeStateTo: (state) ->
      if @_state is state then return Promise.resolve true
      else return Promise.try( =>
        options = _.clone(@config.protocolOptions)
        unless options.all? then options.all = no
        options.state = state
        return @board.rfControlSendMessage(
          @_pluginConfig.transmitterPin, 
          @config.protocol, 
          options
        ).then( =>
          @_setState(state)
          return
        )
      )

  class HomeduinoRFPir extends env.devices.PresenceSensor

    constructor: (@config, @board, @_pluginConfig) ->
      @id = config.id
      @name = config.name

      @_protocol = Board.getRfProtocol(@config.protocol)
      unless @_protocol?
        throw new Error("Could not find a protocol with the name \"#{@config.protocol}\".")
      unless @_protocol.type is "pir"
        throw new Error("\"#{@config.protocol}\" is not a pir protocol.")

      @_presence = no
      resetPresence = ( =>
        @_setPresence(no)
      )

      @board.on('rf', (event) =>
        match = no
        if event.protocol is @config.protocol
          match = yes
          for optName, optValue of @config.protocolOptions
            #console.log "check", optName, optValue, event.values[optName]
            if event.values[optName] isnt optValue
              match = no
        if match
          unless @_setPresence is event.values.presence
            @_setPresence(event.values.presence)
          clearTimeout(@_resetPresenceTimeout)
          @_resetPresenceTimeout = setTimeout(resetPresence, @config.resetTime)
      )
      super()

    getPresence: -> Promise.resolve @_presence


  class HomeduinoRFTemperature extends env.devices.TemperatureSensor

    constructor: (@config, @board) ->
      @id = config.id
      @name = config.name

      @_protocol = Board.getRfProtocol(@config.protocol)
      unless @_protocol?
        throw new Error("Could not find a protocol with the name \"#{@config.protocol}\".")
      unless @_protocol.type is "weather"
        throw new Error("\"#{@config.protocol}\" is not a weather protocol.")

      @attributes = {}

      if @_protocol.values.temperature?
        @attributes.temperature = {
          description: "the messured temperature"
          type: "number"
          unit: '°C'
        }
      if @_protocol.values.humidity?
        @attributes.humidity = {
          description: "the messured humidity"
          type: "number"
          unit: '%'
        }

      @board.on('rf', (event) =>
        match = no
        if event.protocol is @config.protocol
          match = yes
          for optName, optValue of @config.protocolOptions
            #console.log "check", optName, optValue, event.values[optName]
            if event.values[optName] isnt optValue
              match = no
        if match
          now = (new Date()).getTime()
          timeDelta = (
            if @_lastReceiveTime? then (now - @_lastReceiveTime)
            else 9999999
          )
          if timeDelta < 2000
            return 
          if @_protocol.values.temperature?
            @_temperatue = event.values.temperature
            # discard value if it is the same and was received just under two second ago
            @emit "temperature", @_temperatue
          if @_protocol.values.humidity?
            @_humidity = event.values.humidity
            # discard value if it is the same and was received just under two second ago
            @emit "humidity", @_humidity
          @_lastReceiveTime = now
      )
      super()

    getTemperature: -> Promise.resolve @_temperatue
    getHumidity: -> Promise.resolve @_humidity

  hdPlugin = new HomeduinoPlugin()
  return hdPlugin