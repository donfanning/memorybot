#!/usr/bin/env coffee

Entities = require('html-entities').AllHtmlEntities
async = require 'artillery-async'
winston = require 'winston'

log = winston

VERSION = require('../package.json').version

MAX_FACTOID_SIZE = Number(process.env.MAX_FACTOID_SIZE or 2048)

I_DONT_KNOW = [
  "I don't know what that is."
  "I have no idea."
  "No idea."
  "I don't know."
]

OKAY = [
  "OK, got it."
  "I got it."
  "Understood."
  "Gotcha."
  "OK"
]

GREETINGS = [
  "Heya, $who!"
  "Hi $who!"
  "Hello, $who"
  "Hello, $who!"
  "Greetings, $who"
]

ACKNOWLEDGEMENTS = [
  "Yes?"
  "Yep?"
  "Yeah?"
]

IGNORED_FACTOIDS = [
  "he"
  "hers"
  "his"
  "it"
  "it's"
  "its"
  "she"
  "that"
  "them"
  "there"
  "these"
  "they"
  "this"
  "those"
  "what"
  "when"
  "where"
  "who"
  "why"
]

class MemoryBotEngine

  constructor: (@store) ->
    @userIdsToNames = {}

  random: -> Math.random()

  oneOf: ->
    if Array.isArray arguments[0]
      arr = arguments[0]
    else
      arr = arguments
    return arr[Math.floor(@random() * arr.length)]

  handleMessage: (bot, sender, channel, isDirect, msg, done) ->
    team = bot.identifyTeam()

    # Avoid context object (`this`) hell and fat arrows everywhere.
    oneOf = @oneOf.bind this
    userIdsToNames = @userIdsToNames
    store = @store

    {mbMeta} = bot
    shouldLearn = isDirect or mbMeta.ambient
    shouldReply = isDirect or not mbMeta.direct
    isVerbose = mbMeta.verbose

    msg = Entities.decode(msg)
    msg = msg.substr(0, MAX_FACTOID_SIZE).trim().replace(/\0/g, '').replace(/\n/g, ' ')

    reply = (text) ->
      bot.reply {channel: channel}, {text: text}

    parseAndReply = (key, value, tell=null) ->
      [_, verb, rest] = value.match(/^(is|are)\s+(.*)/i)
      value = rest

      value = value.replace(/\\\|/g, '\\&#124;')
      value = oneOf(value.split(/\|/i)).trim()
      value = value.replace(/&#124;/g, '|')

      isReply = (/^<reply>\s*/i).test(value)
      value = value.replace(/^<reply>\s*/i, '') if isReply

      isEmote = (/^<action>\s*/i).test(value)
      value = value.replace(/^<action>\s*/i, '') if isEmote

      value = value.replace(/\$who/ig, sender)

      if tell?
        bot.reply {channel: tell}, {text: "#{sender} wants you to know: #{key} is #{value}"}
        done()
      else if isReply
        reply value
        done()
      else if isEmote
        bot.api.callAPI 'chat.meMessage', {channel: channel, text: value}, (err, res) ->
          log.error(err) if err
          done(err)
      else
        reply "#{key} #{verb} #{value}"
        done()

    update = (key, value) ->
      lastEdit = "on #{new Date()} by #{sender}"
      store.setFactoid team, key, value, lastEdit, (err) ->
        if err
          log.error err
          if isVerbose then reply "There was an error updating that factoid. Please try again."
        else
          if isVerbose or isDirect then reply oneOf OKAY
        done(err)
      return

    # Status
    if isDirect and msg is 'status'
      bool = (x) -> if x then ':ballot_box_with_check:' else ':white_medium_square:'
      store.countFactoids team, (err, count) ->
        log.error err if err
        reply """
          *Status*
          I am memorybot v#{VERSION} - https://statico.github.com/memorybot/
          I am currently remembering #{count} factoids.
          *Settings*
          #{bool mbMeta.direct} `direct` - Interactons require direct messages or @-mentions
          #{bool mbMeta.ambient} `ambient` - Learn factoids from ambient room chatter
          #{bool mbMeta.verbose} `verbose` - Make the bot more chatty with confirmations, greetings, etc.
          Tell me "enable setting <name>" or "disable setting <name>" to change the above settings.
        """
        done(err)
      return

    # Settings
    else if isDirect and (/^(enable|disable)\s+setting\s+/i).test(msg)
      [action, key] = msg.split(/\s+setting\s+/i)
      value = action is 'enable'
      switch key
        when 'direct'
          result = "interactions with me #{if value then 'now' else 'no longer'} require direct messages or @-mentions"
        when 'ambient'
          result = "I #{if value then 'will now' else 'will no longer'} learn factoids without being told explicitly"
        when 'verbose'
          result = "I #{if value then 'will now' else 'will no longer'} be extra chatty"
      async.series [
        (cb) -> store.setMetaData team, key, value, cb
        (cb) -> store.updateBotMetadata bot, cb
      ], (err) ->
        if err
          log.error err
          reply "There was an error updating that setting. Please try again."
        else
          reply "OK, #{result}."
        done(err)
      return

    # A greeting?
    else if (/^(hey|hi|hello|waves)$/i).test(msg)
      if shouldReply or isVerbose
        reply oneOf(GREETINGS).replace(/\$who/ig, sender)
      done()

    # Addressing the bot?
    else if msg.toLowerCase() == "#{bot.identity?.name.toLowerCase()}?"
      reply oneOf ACKNOWLEDGEMENTS
      done()

    # Getting literal factoids
    else if shouldReply and (/^literal\s+/i).test(msg)
      key = msg.replace(/^literal\s+/i, '')
      store.getFactoid team, key, (err, current) ->
        if current?
          reply "#{key} #{current}"
        else
          reply oneOf I_DONT_KNOW
        done(err)
      return

    # Getting regular factoids
    else if shouldReply and (/^wh?at\s+(is|are)\s+/i).test(msg)
      key = msg.replace(/^wh?at\s+(is|are)\s+/i, '').replace(/\?+$/, '')
      return if key.toLowerCase() in IGNORED_FACTOIDS
      store.getFactoid team, key, (err, current) ->
        if not current?
          reply oneOf I_DONT_KNOW
          return
        parseAndReply key, current # Calls done()
      return

    # Getting factoids without an interrogative requires addressing
    else if shouldReply and /\?+$/.test(msg)
      key = msg.replace(/\?+$/, '')
      return if key.toLowerCase() in IGNORED_FACTOIDS
      store.getFactoid team, key, (err, current) ->
        if current?
          parseAndReply key, current # Calls done()
        else
          done(err)
      return

    # Deleting factoids
    else if isDirect and (/^forget\s+/i).test(msg)
      key = msg.replace(/^forget\s+/i, '')
      store.deleteFactoid team, key, (err) ->
        if err
          log.error err
          reply "There was an error while downloading the list of users. Please try again."
        else
          reply "OK, I forgot about #{key}"
        done(err)
      return

    # Tell users about things
    else if (/^tell\s+\S+\s+about\s+/i).test(msg)
      bot.api.users.list {}, (err, res) ->
        if err
          log.error err
          if isDirect then reply "There was an error while downloading the list of users. Please try again."
          return done(err)

        msg = msg.replace(/^tell\s+/i, '')
        [targetName, parts...] = msg.split(/\s*about\s*/i)
        key = parts.join(' ')

        targetID = null
        for {id, name} in res.members
          userIdsToNames[id] = name
          if name is targetName
            targetID = id

        if targetID is null
          reply "I don't know who #{targetName} is."
          return done()

        store.getFactoid team, key, (err, value) ->
          if not value?
            reply oneOf I_DONT_KNOW
            return done()

          bot.api.im.open {user: targetID}, (err, res) ->
            if err
              log.error err
              if shouldReply then reply "I could not start an IM session with #{targetName}. Please try again."
              return done(err)

            targetChannel = res.channel?.id
            parseAndReply key, value, targetChannel
            if shouldReply or isVerbose
              reply "OK, I told #{targetName} about #{key}"
            done()

        return
      return

    # Karma query
    else if (/^karma\s+for\s+/i).test(msg)
      key = msg.replace(/^karma\s+for\s+/i, '').replace(/\?+$/, '')
      store.getKarma team, key, (err, current) ->
        current or= 0
        if err
          log.error err
          if isVerbose then reply "There was an error getting the karma. Please try again."
        else
          reply "#{key} has #{current} karma"
        done(err)
      return

    # Karma increment/decrement
    else if /\+\+(\s#.+)?$/.test(msg)
      if isDirect then return reply "You cannot secretly change the karma for something!"
      key = msg.split(/\+\+/)[0]
      store.getKarma team, key, (err, current) ->
        if err
          log.error(err)
          return done(err)
        value = Number(current or 0)
        value++
        store.setKarma team, key, value, (err) ->
          if err
            log.error err
            if isVerbose then reply "There was an error changing the karma. Please try again."
          done(err)
        return
      return

    # Karma decrement
    else if /\-\-(\s#.+)?$/.test(msg)
      if isDirect then return reply "You cannot secretly change the karma for something!"
      key = msg.split(/\-\-/)[0]
      store.getKarma team, key, (err, current) ->
        if err
          log.error(err)
          return done(err)
        value = Number(current or 0)
        value--
        store.setKarma team, key, value, (err) ->
          if err
            log.error err
            if isVerbose then reply "There was an error changing the karma. Please try again."
          done(err)
        return
      return

    # Updating factoids
    else if shouldLearn and (/\s+(is|are)\s+/i).test(msg)
      [_, key, verb, value] = msg.match /^(.+?)\s+(is|are)\s+(.*)/i
      key = key.toLowerCase()
      verb = verb.toLowerCase()

      if key in IGNORED_FACTOIDS
        return done()

      isCorrecting = (/no,?\s+/i).test(key)
      key = key.replace(/no,?\s+/i, '') if isCorrecting

      isAppending = (/also,?\s+/i).test(key)
      key = key.replace(/also,?\s+/i, '') if isAppending

      isAppending or= (/also,?\s+/i).test(value)
      value = value.replace(/also,?\s+/i, '') if isAppending

      store.getFactoid team, key, (err, current) ->
        if err
          log.error(err)
          return done(err)

        if current and isCorrecting
          return update key, "#{verb} #{value}" # Calls done()

        else if current and isAppending
          if /^\|/.test value
            value = "#{current}#{value}"
          else
            value = "#{current} or #{value}"
          return update key, value # Calls done()

        else if current == value
          reply oneOf "I already know that.", "I've already got it as that."
          done()

        else if current
          current = current.replace(/^(is|are)\s+/i, '')
          reply "But #{key} #{verb} already #{current}"
          done()

        else
          return update key, "#{verb} #{value}" # Calls done()

      return

    # Getting regular factoids, last chance
    else
      if msg.toLowerCase() in IGNORED_FACTOIDS
        return done()
      store.getFactoid team, msg, (err, value) ->
        if value?
          parseAndReply msg, value # Calls done()
      return

    return

exports.MemoryBotEngine = MemoryBotEngine