## Has to be compiled with 
## '-d:ssl' flag

import asyncdispatch, discordnim

proc messageCreateProc(s: Shard, m: MessageCreate) =
    if s.cache.me.id == m.author.id: return
    if m.content == "my-roles":
        var roles: seq[Role] = @[]
        
        # Check the cache for the guild first
        var (guild, exists) = s.cache.getGuild("214858616140857355")

        if not exists:
            # If it doesn't exist in the cache 
            # we'll request the guild and cache it at the same time.
            # I'd recommend only using the session functions
            # since they check the cache first before
            # making a request to the api.
            guild = waitFor s.guild("214858616140857355")

        # This should be getting it from the cache since
        # we have cacheGuild(Members) set to true.
        var member = waitFor s.guildMember("214858616140857355", $m.author.id)
        
        for role in member.roles:
            let r = waitFor s.guildRole("214858616140857355", role)
            roles.add(r)
        
        asyncCheck s.channelmessageSend(m.channel_id, $roles)
        # Sends "@[(id: 299604263133380629, name: Foo, color: 2067276, hoist: false, position: 1, permissions: 2146958463, managed: false, mentionable: true)]"

let shard = newShard("Bot <Token>")
discard shard.addHandler(message_create, messageCreateProc)

proc endSession() {.noconv.} =
    waitFor shard.disconnect()

setControlCHook(endSession)

shard.cache.cacheChannels = true
shard.cache.cacheGuilds = true
shard.cache.cacheRoles = true
shard.cache.cacheGuildMembers = true
shard.cache.cacheUsers = true

waitFor shard.startSession()