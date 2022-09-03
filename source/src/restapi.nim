include endpoints
import httpclient, asyncdispatch, json, tables,  re,
    strutils, objects, ospaths, mimetypes, uri, options

proc request(s: Shard,
                bucketid, meth, url, contenttype, b: string = "",
                sequence: int = 0,
                mp: MultipartData = nil,
                xheaders: HttpHeaders = nil): Future[AsyncResponse] {.gcsafe, async.} =
    var id: string
    if bucketid == "" or url.contains('?'):
        id = split(url, "?", 2)[0]
    else:
        id = bucketid
    await s.limiter.preCheck(id)

    let client = newAsyncHttpClient("DiscordBot (https://github.com/Krognol/discordnim, v" & VERSION & ")")

    client.headers["Authorization"] = s.token
    client.headers["Content-Type"] = contenttype 
    client.headers["Content-Length"] = $(b.len)
    if mp == nil: 
        result = await client.request(url, meth, b)
    else:
        if meth == "POST":
            result = await client.post(url, b, mp)
    client.close()

    if (await s.limiter.postCheck(url, result)) and sequence < 5:
        echo "You got ratelimited"
        result = await s.request(id, meth, url, contenttype, b, sequence+1)

proc doreq(s: Shard, meth, endpoint, payload: string = "", xheaders: HttpHeaders = nil, mpd: MultipartData = nil): Future[JsonNode] {.gcsafe, async.} =
    let res = await s.request(endpoint, meth, endpoint, "application/json", payload, 0, xheaders = xheaders)
    result = (await res.body).parseJson

proc channel*(s: Shard, channel_id: string): Future[Channel] {.gcsafe, async.} =
    result = (await doreq(s, endpointChannels(channel_id))).newChannel

proc channelEdit*(s: Shard, channelid: string, params: ChannelParams, reason: string = ""): Future[Guild] {.gcsafe, async.} =
    ## Edits a channel with the ChannelParams
    var xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", endpointChannels(channelid), $(%params), xh)).newGuild

proc deleteChannel*(s: Shard, channelid: string, reason: string = ""): Future[Channel] {.gcsafe, async.} =
    ## Deletes a channel
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "DELETE", endpointChannels(channelid), xheaders = xh)).newChannel

proc channelMessages*(s: Shard, channelid: string, before, after, around: string, limit: int): Future[seq[Message]] {.gcsafe, async.} =
    ## Returns a channels messages
    ## Maximum of 100 messages
    var url = endpointChannelMessages(channelid) & "?"
    
    if before != "":
        url = url & "before=" & before & "&"
    if after != "":
        url = url & "after=" & after & "&"
    if around != "":
        url = url & "around=" & around & "&"
    if limit > 0 and limit <= 100:
        url = url & "limit=" & $limit
    
    let node = (await doreq(s, "GET", url))

    result = newSeq[Message](node.elems.len)
    for i, n in node.elems: 
        result[i] = newMessage(n)
    

proc channelMessage*(s: Shard, channelid, messageid: string): Future[Message] {.gcsafe, async, inline.} =
    ## Returns a message from a channel
    result = (await doreq(s, "GET", endpointChannelMessage(channelid, messageid))).newMessage

proc channelMessageSend*(s: Shard, channelid, message: string): Future[Message] {.gcsafe, async.} =
    ## Sends a regular text message to a channel
    let payload = %*{"content": message}
    result = (await doreq(s, "POST", endpointChannelMessages(channelid), $payload)).newMessage

proc channelMessageSendEmbed*(s: Shard, channelid: string, embed: Embed): Future[Message] {.gcsafe, async, inline.} =
    ## Sends an Embed message to a channel
    result = (await doreq(s, "POST", endpointChannelMessages(channelid),
        $(%*{
            "content": "",
            "embed": embed,
        }))).newMessage

proc channelMessageSendTTS*(s: Shard, channelid, message: string): Future[Message] {.gcsafe, async, inline.} =
    ## Sends a TTS message to a channel
    result = (await doreq(s, "POST", endpointChannelMessages(channelid), 
        $(%*{
            "content": message,
            "tts": true
        }))).newMessage

proc channelFileSendWithMessage*(s: Shard, channelid, name, message: string): Future[Message] {.gcsafe, async.} =
    ## Sends a file to a channel along with a message
    let payload = %*{"content": message}
    var data = newMultipartData()
    data = data.addFiles({"file": name})
    data.add("payload_json", $payload, contentType = "application/json")
    result = (await doreq(s, "POST", endpointChannelMessages(channelid), mpd = data)).newMessage

proc channelFileSendWithMessage*(s: Shard, channelid, name, fbody, message: string): Future[Message] {.gcsafe, async.} =
    ## Sends the contents of a file as a file to a channel.
    var data = newMultipartData()
    if name == "":
        raise newException(Exception, "Parameter `name` of `channelFileSendWithMessage` can't be empty and has to have an extension")
    let payload = %*{"content": message}
    var contenttype: string 
    let (_, fname, ext) = splitFile(name)
    if ext.len > 0: contenttype = newMimetypes().getMimetype(ext[1..high(ext)])
    
    data.add(name, fbody, fname & ext, contenttype)
    data.add("payload_json", $payload, contentType = "application/json")
    result = (await doreq(s, "POST", endpointChannelMessages(channelid), mpd = data)).newMessage

proc channelFileSend*(s: Shard, channelid, fname: string): Future[Message] {.gcsafe, inline, async.} =
    ## Sends a file to a channel
    result = await s.channelFileSendWithMessage(channelid, fname, "")

proc channelFileSend*(s: Shard, channelid, fname, fbody: string): Future[Message] {.gcsafe, inline, async.} =
    ## Sends the contents of a file as a file to a channel.
    result = await s.channelFileSendWithMessage(channelid, fname, fbody, "")

proc channelMessageReactionAdd*(s: Shard, channelid, messageid, emojiid: string) {.gcsafe, inline, async.} = 
    ## Adds a reaction to a message
    asyncCheck doreq(s, "PUT", endpointMessageReactions(channelid, messageid, emojiid))

proc messageDeleteOwnReaction*(s: Shard, channelid, messageid, emojiid: string) {.gcsafe, inline, async.} =
    ## Deletes your own reaction to a message
    asyncCheck doreq(s, "DELETE", endpointOwnReactions(channelid, messageid, emojiid))

proc messageDeleteReaction*(s: Shard, channelid, messageid, emojiid, userid: string) {.gcsafe, inline, async.} =
    ## Deletes a reaction from a user from a message
    asyncCheck doreq(s, "DELETE", endpointMessageUserReaction(channelid, messageid, emojiid, userid))

proc messageGetReactions*(s: Shard, channelid, messageid, emojiid: string): Future[seq[User]] {.gcsafe, inline, async.} =
    ## Gets a message's reactions
    let node = (await doreq(s, "GET", endpointMessageReactions(channelid, messageid, emojiid)))
    result = newSeq[User](node.elems.len)
    for i, n in node.elems:
        result[i] = newUser(n)

proc messageDeleteAllReactions*(s: Shard, channelid, messageid: string) {.gcsafe, inline, async.} =
    ## Deletes all reactions on a message
    asyncCheck doreq(s, "DELETE", endpointReactions(channelid, messageid))

proc channelMessageEdit*(s: Shard, channelid, messageid, content: string): Future[Message] {.gcsafe, inline, async.} =
    ## Edits a message's contents
    result = (await doreq(s, "PATCH", endpointChannelMessage(channelid, messageid), $(%*{"content": content}))).newMessage
    
proc channelMessageDelete*(s: Shard, channelid, messageid: string, reason: string = "") {.gcsafe, async.} =
    ## Deletes a message
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", endpointChannelMessage(channelid, messageid), xheaders = xh)

proc channelMessagesDeleteBulk*(s: Shard, channelid: string, messages: seq[string]) {.gcsafe, async, inline.} =
    ## Deletes messages in bulk.
    ## Will not delete messages older than 2 weeks
    asyncCheck doreq(s, "DELETE", endpointBulkDelete(channelid), $(%*{"messages": messages}))

proc channelEditPermissions*(s: Shard, channelid: string, overwrite: Overwrite, reason: string = "") {.gcsafe, async.} =
    ## Edits a channel's permissions
    let payload = %*{
        "type": overwrite.`type`, 
        "allow": overwrite.allow, 
        "deny": overwrite.deny
    }
    let xh: HttpHeaders = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PUT", endpointChannelPermissions(channelid, overwrite.id), $payload, xh)

proc channelInvites*(s: Shard, channel: string): Future[seq[Invite]] {.gcsafe, inline, async.} =
    ## Returns all invites to a channel
    let node = (await doreq(s, "GET", endpointChannelInvites(channel)))
    result = newSeq[Invite](node.elems.len)
    for i, n in node.elems:
        result[i] = newInvite(n)

proc channelCreateInvite*(
                s: Shard, 
                channel: string, 
                max_age, max_uses: int, 
                temp, unique: bool, 
                reason: string = ""): Future[Invite] 
                {.gcsafe, async.} =
    ## Creates an invite to a channel
    let payload = %*{"max_age": max_age, "max_uses": max_uses, "temp": temp, "unique": unique}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", endpointChannelInvites(channel), $payload, xh)).newInvite

proc channelDeletePermission*(s: Shard, channel, target: string, reason: string = "") {.gcsafe, async.} =
    ## Deletes a channel permission
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", endpointCHannelPermissions(channel, target), xheaders = xh)

proc typingIndicatorTrigger*(s: Shard, channel: string) {.gcsafe, async, inline.} =
    ## Triggers the "X is typing" indicator
    asyncCheck doreq(s, "POST", endpointTriggerTypingIndicator(channel))

proc channelPinnedMessages*(s: Shard, channel: string): Future[seq[Message]] {.gcsafe, inline, async.} =
    ## Returns all pinned messages in a channel
    let node = (await doreq(s, "GET", endpointCHannelPinnedMessages(channel)))
    result = newSeq[Message](node.elems.len)
    for i, n in node.elems:
        result[i] = newMessage(n)
    
proc channelPinMessage*(s: Shard, channel, message: string) {.gcsafe, inline, async.} =
    ## Pins a message in a channel
    asyncCheck doreq(s, "PUT", endpointPinnedChannelMessage(channel, message))

proc channelDeletePinnedMessage*(s: Shard, channel, message: string) {.gcsafe, inline, async.} =
    asyncCheck doreq(s, "DELETE", endpointPinnedChannelMessage(channel, message))

# This might work?
type AddGroupDMUser* = object
    id: string
    nick: string

# This might work?
proc groupDMCreate*(s: Shard, accesstokens: seq[string], nicks: seq[AddGroupDMUser]): Future[Channel] {.gcsafe, async, inline.} =
    ## Creates a group DM channel
    result = (await doreq(s, "POST", endpointDM(), $(
         %*{
            "access_tokens": accesstokens, 
            "nicks": nicks
        }
    ))).newChannel

proc groupDMAddUser*(s: Shard, channelid, userid, access_token, nick: string) {.gcsafe, async, inline.} =
    ## Adds a user to a group dm.
    ## Requires the 'gdm.join' scope.
    asyncCheck doreq(s, "PUT", endpointGroupDMRecipient(channelid, userid), $(
        %*{
            "access_token": access_token, 
            "nick": nick
        }
    ))
    
proc groupdDMRemoveUser*(s: Shard, channelid, userid: string) {.gcsafe, inline, async.} =
    ## Removes a user from a group dm.
    asyncCheck doreq(s, "DELETE", endpointGroupDMRecipient(channelid, userid))

type
    PartialChannel* = object
        name*: string
        `type`*: int

proc newPartialChannel*(name: string, typ: int = 0): PartialChannel {.inline.} = PartialChannel(name: name, `type`: typ)

proc createGuild*(s: Shard, 
        name, region, icon: string, 
        roles: seq[Role] = @[], channels: seq[PartialChannel] = @[], 
        verlvl, defmsgnot: int): Future[Guild] {.gcsafe, async, inline.} =
    ## Creates a guild.
    ## This endpoint is limited to 10 active guilds
    result = (await doreq(s, "POST", endpointGuilds(), $(
        %*{
            "name": name,
            "region": region,
            "icon": icon,
            "verification_level": verlvl,
            "default_message_notifications": defmsgnot,
            "roles": roles,
            "channels": channels
        }
    ))).newGuild
    
proc guild*(s: Shard, id: string): Future[Guild] {.gcsafe, async.} =
    ## Gets a guild
    result = (await doreq(s, "GET", endpointGuild(id))).newGuild

proc guildEdit*(s: Shard, guild: string, settings: GuildParams, reason: string = ""): Future[Guild] {.gcsafe, async.} =
    ## Edits a guild with the GuildParams
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "PATCH", endpointGuild(guild), $(%settings), xh)).newGuild

proc deleteGuild*(s: Shard, guild: string): Future[Guild] {.gcsafe, inline, async.} =
    ## Deletes a guild
    asyncCheck doreq(s, "DELETE", endpointGuild(guild))
    
proc guildChannels*(s: Shard, guild: string): Future[seq[Channel]] {.gcsafe, async.} =
    ## Returns all guild channels
    let node = (await doreq(s, "GET", endpointGuildChannels(guild)))
    result = newSeq[Channel](node.elems.len)
    for i, n in node.elems:
        result[i] = newChannel(n)

proc guildChannelCreate*(
    s: Shard, 
    guild, channelname, parentId: string, 
    rateLimit: int, 
    voice, nsfw: bool,
    permOW: seq[Overwrite],
    reason: string = ""): Future[Channel] {.gcsafe, async.} =
    ## Creates a new channel in a guild
    var payload = %*{"name": channelname, "parent_id": parentId, "voice": voice, "rate_limit_per_user": rateLimit, "nsfw": nsfw}
    if permOW.len > 0: payload["permission_overwrites"] = %permOW
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", endpointGuildChannels(guild), $payload, xh)).newChannel

proc guildChannelPositionEdit*(s: Shard, guild, channel: string, position: int, reason: string = ""): Future[seq[Channel]] {.gcsafe, async.} =
    ## Reorders the position of a channel and returns the new order
    let payload = %*{"id": channel, "position": position}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    let node = (await doreq(s, "PATCH", endpointGuildChannels(guild), $payload, xh))
    result = newSeq[Channel](node.elems.len)
    for i, n in node.elems:
        result[i] = newChannel(n)

proc guildMembers*(s: Shard, guild: string, limit, after: int): Future[seq[GuildMember]] {.gcsafe, async.} =
    ## Returns up to 1000 guild members
    var url = endpointGuildMembers(guild) & "?"
    if limit > 1:
        url &= "limit=" & $limit & "&"
    if after > 0:
        url &= "after=" & $after & "&"

    let node = (await doreq(s, "GET", url))
    result = newSeq[GuildMember](node.elems.len)
    for i, n in node.elems:
        result[i] = newGuildMember(n)

proc guildMember*(s: Shard, guild, userid: string): Future[GuildMember] {.gcsafe, async.} =
    ## Returns a guild member with the userid
    result = (await doreq(s, "GET", endpointGuildMember(guild, userid))).newGuildMember

proc guildAddMember*(s: Shard, guild, userid, accesstoken: string): Future[GuildMember] {.gcsafe, async.} =
    ## Adds a guild member to the guild
    result = (await doreq(s, "PUT", endpointGuildMember(guild, userid), $(
        %*{
            "access_token": accesstoken
        }
    ))).newGuildMember

proc guildMemberRolesEdit*(s: Shard, guild, userid: string, roles: seq[string]) {.gcsafe, async.} =
    ## Edits a guild member's roles
    asyncCheck doreq(s, "PATCH", endpointGuildMember(guild, userid), $(%*{"roles": roles}))

proc guildMemberSetNickname*(s: Shard, guild, userid, nick: string, reason: string = "") {.gcsafe, async.} =
    ## Sets the nickname of a member
    asyncCheck doreq(s, "PATCH", endpointGuildMember(guild, userid), $(%*{"nick": nick}))

proc guildMemberMute*(s: Shard, guild, userid: string, mute: bool, reason: string = "") {.gcsafe, async.} =
    ## Mutes a guild member
    let payload = %*{"mute": mute}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PATCH", endpointGuildMember(guild, userid), $payload, xh)

proc guildMemberDeafen*(s: Shard, guild, userid: string, deafen: bool, reason: string = "") {.gcsafe, async.} =
    ## Deafens a guild member
    let payload = %*{"deaf": deafen}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PATCH", endpointGuildMember(guild, userid), $payload, xh)
 
proc guildMemberMove*(s: Shard, guild, userid, channel: string, reason: string = "") {.gcsafe, async.} =
    ## Moves a guild member from one channel to another
    ## only works if they are connected to a voice channel
    let payload = %*{"channel_id": channel}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PATCH", endpointGuildMember(guild, userid), $payload, xh)

proc setNickname*(s: Shard, guild, nick: string, reason: string = "") {.gcsafe, async.} =
    ## Sets the nick for the current user
    let payload = %*{"nick": nick}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PATCH", endpointEditNick(guild), $payload, xh)

proc guildMemberAddRole*(s: Shard, guild, userid, roleid: string, reason: string = "") {.gcsafe, async.} =
    ## Adds a role to a guild member
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PUT", endpointGuildMemberRoles(guild, userid, roleid), xheaders = xh)

proc guildMemberRemoveRole*(s: Shard, guild, userid, roleid: string, reason: string = "") {.gcsafe, async.} =
    ## Removes a role from a guild member
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", endpointGuildMemberRoles(guild, userid, roleid), xheaders = xh)

proc guildRemoveMemberWithReason*(s: Shard, guild, userid, reason: string) {.gcsafe, async.} =
    var url = endpointGuildMember(guild, userid)
    if reason != "": url &= "?reason=" & encodeUrl(reason)
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", url, xheaders = xh)

proc guildRemoveMember*(s: Shard, guild, userid: string, reason: string = "") {.gcsafe, inline, async.} =
    ## Removes a guild membe from the guild
    asyncCheck s.guildRemoveMemberWithReason(guild, userid, "")

proc guildBans*(s: Shard, guild: string): Future[seq[User]] {.gcsafe, inline, async.} =
    ## Returns all users who have been banned from the guild
    let node = (await doreq(s, "GET", endpointGuildBans(guild)))
    result = newSeq[User](node.elems.len)
    for i, n in node.elems:
        result[i] = newUser(n)

proc guildUserBan*(s: Shard, guild, userid: string, reason: string = "") {.gcsafe, async.} =
    ## Bans a user from the guild
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "PUT", endpointGuildBan(guild, userid), xheaders = xh)

proc guildRemoveBan*(s: Shard, guild, userid: string, reason: string = "") {.gcsafe, async.} =
    ## Removes a ban from the guild
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", endpointGuildBan(guild, userid), xheaders = xh)

proc guildRoles*(s: Shard, guild: string): Future[seq[Role]] {.gcsafe, async.} =
    ## Returns all guild roles
    let node = (await doreq(s, "GET", endpointGuildRoles(guild)))
    result = newSeq[Role](node.elems.len)
    for i, n in node.elems:
        result[i] = newRole(n)
    
proc guildRole*(s: Shard, guild, roleid: string): Future[Role] {.gcsafe, async.} =
    ## Returns a role with the given id.
    let roles = await s.guildRoles(guild)
    for role in roles:
        if role.id == roleid:
            return role

proc guildCreateRole*(s: Shard, guild: string, reason: string = ""): Future[Role] {.gcsafe, async.} =
    ## Creates a new role in the guild
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", endpointGuildRoles(guild), xheaders = xh)).newRole
    
proc guildEditRolePosition*(s: Shard, guild: string, roles: seq[Role], reason: string = ""): Future[seq[Role]] {.gcsafe, async.} =
    ## Edits the positions of a guilds roles roles
    ## and returns the new roles order
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    let node = (await doreq(s, "PATCH", endpointGuildRoles(guild), $(%roles), xh))
    result = newSeq[Role](node.elems.len)
    for i, n in node.elems:
        result[i] = newRole(n)

proc guildEditRole*(
            s: Shard, 
            guild, roleid, name: string, 
            permissions, color: int, 
            hoist, mentionable: bool,
            reason: string = ""): Future[Role] 
            {.gcsafe, async.} =
    ## Edits a role
    let payload = %*{"name": name, "permissions": permissions, "color": color, "hoist": hoist, "mentionable": mentionable}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "PATCH", endpointGuildRole(guild, roleid), $payload, xh)).newRole
   
proc guildDeleteRole*(s: Shard, guild, roleid: string, reason: string = "") {.gcsafe, async.} =
    ## Deletes a role
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    asyncCheck doreq(s, "DELETE", endpointGuildRole(guild, roleid), xheaders = xh)

proc guildPruneCount*(s: Shard, guild: string, days: int): Future[int] {.gcsafe, async.} =
    ## Returns the number of members who would get kicked
    ## during a prune operation
    var url = endpointGuildPruneCount(guild) & "?days=" & $days
    result = (await doreq(s, "GET", url))["pruned"].getInt()

proc guildPruneBegin*(s: Shard, guild: string, days: int, reason: string = ""): Future[int] {.gcsafe, async.} =
    ## Begins a prune operation and
    ## kicks all members who haven't been active
    ## for N days
    var url = endpointGuildPruneCount(guild) & "?days=" & $days
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", url, xheaders = xh))["pruned"].getInt()

proc guildVoiceRegions*(s: Shard, guild: string): Future[seq[VoiceRegion]] {.gcsafe, inline, async.} =
    ## Lists all voice regions in a guild
    let node = (await doreq(s, "GET", endpointGuildVoiceRegions(guild)))
    result = newSeq[VoiceRegion](node.elems.len)
    for i, n in node.elems:
        result[i] = newVoiceRegion(n)
    
proc guildInvites*(s: Shard, guild: string): Future[seq[Invite]] {.gcsafe, inline, async.} =
    ## Lists all guild invites
    let node = (await doreq(s, "GET", endpointGuildInvites(guild)))
    result = newSeq[Invite](node.elems.len)
    for i, n in node.elems:
        result[i] = newInvite(n)

proc guildIntegrations*(s: Shard, guild: string): Future[seq[Integration]] {.gcsafe, inline, async.} =
    ## Lists all guild integrations
    let node = (await doreq(s, "GET", endpointGuildIntegrations(guild)))
    result = newSeq[Integration](node.elems.len)
    for i, n in node.elems:
        result[i] = newIntegration(n)

proc guildIntegrationCreate*(s: Shard, guild, typ, id: string) {.gcsafe, async.} =
    ## Creates a new guild integration
    let payload = %*{"type": typ, "id": id}
    asyncCheck doreq(s, "POST", endpointGuildIntegrations(guild), $payload)

proc guildIntegrationEdit*(s: Shard, guild, integrationid: string, behaviour, grace: int, emotes: bool) {.gcsafe, async.} =
    ## Edits a guild integration
    let payload = %*{"expire_behavior": behaviour, "expire_grace_period": grace, "enable_emoticons": emotes}
    asyncCheck doreq(s, "PATCH", endpointGuildIntegration(guild, integrationid), $payload)

proc guildIntegrationDelete*(s: Shard, guild, integration: string) {.gcsafe, inline, async.} =
    ## Deletes a guild Integration
    asyncCheck doreq(s, "DELETE", endpointGuildIntegration(guild, integration))

proc guildIntegrationSync*(s: Shard, guild, integration: string) {.gcsafe, inline, async.} =
    ## Syncs an existing guild integration
    asyncCheck doreq(s, "POST", endpointSyncGuildIntegration(guild, integration))

proc guildEmbed*(s: Shard, guild: string): Future[GuildEmbed] {.gcsafe, inline, async.} =
    ## Gets a GuildEmbed
    result = (await doreq(s, "GET", endpointGuildEmbed(guild))).newGuildEmbed
    
proc guildEmbedEdit*(s: Shard, guild: string, enabled: bool, channel: string): Future[GuildEmbed] {.gcsafe, async.} =
    ## Edits a GuildEmbed
    let embed = GuildEmbed(enabled: enabled, channel_id: some(channel))
    result = (await doreq(s, "PATCH", endpointGuildEmbed(guild), $(%embed))).newGuildEmbed

proc guildEmojiCreate*(s: Shard, guild, name, image: string, roles: seq[string] = @[]): Future[Emoji] {.gcsafe, async.} =
    let payload = %*{
        "name": name,
        "image": image,
        "roles": roles
    }
    result = (await doreq(s, "POST", endpointGuildEmojis(guild), $payload)).newEmoji

proc guildEmojiUpdate*(s: Shard, guild, emoji, name: string, roles: seq[string] = @[]): Future[Emoji] {.gcsafe, async.} =
    ## Updates a guild emoji
    let payload = %*{
        "name": name,
        "roles": roles
    }
    result = (await doreq(s, "PATCH", endpointGuildEmoji(guild, emoji), $payload)).newEmoji

proc guildEmojiDelete*(s: Shard, guild, emoji: string) {.gcsafe, async.} =
    asyncCheck doreq(s, "DELETE", endpointGuildEmoji(guild, emoji))

proc guildAuditLog*(s: Shard, guild: string, 
                        user_id: string = "", action_type: int = -1, 
                        before: string = "", limit: int = 50): Future[AuditLog]
                        {.gcsafe, async.} =
    
    var url = endpointGuildAuditLog(guild) & "?"
    if user_id != "": url &= "user_id=" & user_id & "&"
    if action_type >= 1: url &= "action_type" & $action_type & "&"
    if before != "": url &= "before=" & before & "&"
    url &= "limit=" & $limit
    result = (await doreq(s, "GET", url)).newAuditLog

proc invite*(s: Shard, code: string): Future[Invite] {.gcsafe, inline, async.} =
    ## Gets an invite with code
    result = (await doreq(s, "GET", endpointInvite(code))).newInvite
   
proc inviteDelete*(s: Shard, code: string, reason: string = ""): Future[Invite] {.gcsafe, async.} =
    ## Deletes an invite
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "DELETE", endpointInvite(code), xheaders = xh)).newInvite
    
proc me*(s: Shard): User {.gcsafe, inline.} =
    ## Returns the current user
    result = s.cache.me 

proc user*(s: Shard, userid: string): Future[User] {.gcsafe, async.} =
    ## Gets a user
    if userid == s.cache.me.id: return s.cache.me
    result = (await doreq(s, "GET", endpointUser(userid))).newUser
        
proc usernameEdit*(s: Shard, name: string): Future[User] {.gcsafe, inline, async.} =
    ## Edits the current users username
    result = (await doreq(s, "PATCH", endpointCurrentUser(), $(%*{"username": name}))).newUser

proc avatarEdit*(s: Shard, avatar: string): Future[User] {.gcsafe, inline, async.} =
    ## Changes the current users avatar
    result = (await doreq(s, "PATCH", endpointCurrentUser(), $(%*{"avatar": avatar}))).newUser

proc currentUserGuilds*(s: Shard): Future[seq[UserGuild]] {.gcsafe, inline, async.} =
    ## Lists the current users guilds
    let node = (await doreq(s, "GET", endpointCurrentUserGuilds())) 
    result = newSeq[UserGuild](node.elems.len)
    for i, n in node.elems:
        result[i] = newUserGuild(n)

proc leaveGuild*(s: Shard, guild: string) {.gcsafe, inline, async.} =
    ## Makes the current user leave the specified guild
    asyncCheck doreq(s, "DELETE", endpointLeaveGuild(guild))

proc activePrivateChannels*(s: Shard): Future[seq[Channel]] {.gcsafe, inline, async.} =
    ## Lists all active DM channels
    let node = (await doreq(s, "GET", endpointUserDMs()))
    result = newSeq[Channel](node.elems.len)
    for i, n in node.elems:
        result[i] = newChannel(n)

proc privateChannelCreate*(s: Shard, recipient: string): Future[Channel] {.gcsafe, inline, async.} =
    ## Creates a new DM channel
    result = (await doreq(s, "POST", endpointDM(), $(%*{"recipient_id": recipient}))).newChannel
    
proc voiceRegions*(s: Shard): Future[seq[VoiceRegion]] {.gcsafe, inline, async.} =
    ## Lists all voice regions
    let node = (await doreq(s, "GET", endpointListVoiceRegions()))
    result = newSeq[VoiceRegion](node.elems.len)
    for i, n in node.elems:
        result[i] = newVoiceRegion(n)

proc webhookCreate*(s: Shard, channel, name, avatar: string, reason: string = ""): Future[Webhook] {.gcsafe, async.} =
    ## Creates a webhook
    let payload = %*{"name": name, "avatar": avatar}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "POST", endpointWebhooks(channel), $payload, xh)).newWebhook

proc channelWebhooks*(s: Shard, channel: string): Future[seq[Webhook]] {.gcsafe, inline, async.} =
    ## Lists all webhooks in a channel
    let node = (await doreq(s, "GET", endpointWebhooks(channel)))
    result = newSeq[Webhook](node.elems.len)
    for i, n in node.elems:
        result[i] = newWebhook(n)

proc guildWebhooks*(s: Shard, guild: string): Future[seq[Webhook]] {.gcsafe, inline, async.} =
    ## Lists all webhooks in a guild
    let node = (await doreq(s, "GET", endpointGuildWebhooks(guild)))
    result = newSeq[Webhook](node.elems.len)
    for i, n in node.elems:
        result[i] = newWebhook(n)

proc getWebhookWithToken*(s: Shard, webhook, token: string): Future[Webhook] {.gcsafe, inline, async.} =
    ## Gets a webhook with a token
    result = (await doreq(s, "GET", endpointWebhookWithToken(webhook, token))).newWebhook

proc webhookEdit*(s: Shard, webhook, name, avatar: string, reason: string = ""): Future[Webhook] {.gcsafe, async.} =
    ## Edits a webhook
    let payload = %*{"name": name, "avatar": avatar}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "PATCH", endpointWebhook(webhook), $payload, xh)).newWebhook
    
proc webhookEditWithToken*(s: Shard, webhook, token, name, avatar: string, reason: string = ""): Future[Webhook] {.gcsafe, async.} =
    ## Edits a webhook with a token
    let payload = %*{"name": name, "avatar": avatar}
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "PATCH", endpointWebhookWithToken(webhook, token), $payload, xh)).newWebhook

proc webhookDelete*(s: Shard, webhook: string, reason: string = ""): Future[Webhook] {.gcsafe, async.} =
    ## Deletes a webhook
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "DELETE", endpointWebhook(webhook), xheaders = xh)).newWebhook

proc webhookDeleteWithToken*(s: Shard, webhook, token: string, reason: string = ""): Future[Webhook] {.gcsafe, async.} =
    ## Deltes a webhook with a token
    let xh = if reason != "": newHttpHeaders({"X-Audit-Log-Reason": reason}) else: nil
    result = (await doreq(s, "DELETE", endpointWebhookWithToken(webhook, token), xheaders = xh)).newWebhook

proc executeWebhook*(s: Shard, webhook, token: string, payload: WebhookParams) {.gcsafe, inline, async.} =
    ## Executes a webhook
    asyncCheck doreq(s, "POST", endpointWebhookWithToken(webhook, token), $(%payload))

proc `$`*(u: User): string {.gcsafe, inline.} =
    ## Stringifies a user.
    ##
    ## e.g: Username#1234
    result = u.username.get() & "#" & u.discriminator.get()

proc `$`*(c: Channel): string {.gcsafe, inline.} =
    ## Stringifies a channel.
    ##
    ## e.g: #channel-name 
    result = "#" & c.name.get("")

proc `$`*(e: Emoji): string {.gcsafe, inline.} =
    ## Stringifies an emoji.
    ##
    ## e.g: :emojiName:129837192873
    result = ":" & e.name & ":" & e.id.get("")

proc `@`*(u: User): string {.gcsafe, inline.} =
    ## Returns a message formatted user mention.
    ##
    ## e.g: <@109283102983019283>
    result = "<@" & u.id & ">"

proc `@`*(c: Channel): string {.gcsafe, inline.} = 
    ## Returns a message formatted channel mention.
    ##
    ## e.g: <#1239810283>
    result = "<#" & c.id & ">"

proc `@`*(r: Role): string {.gcsafe, inline.} =
    ## Returns a message formatted role mention
    ##
    ## e.g: <@&129837128937>
    result = "<@&" & r.id & ">"

proc `@`*(e: Emoji): string {.gcsafe, inline.} =
    ## Returns a message formated emoji.
    ##
    ## e.g: <:emojiName:1920381>
    result = "<" & $e & ">"

proc defaultAvatar*(u: User): string =
    ## Returns the avatar url of the user.
    ##
    ## If the user doesn't have an avatar it returns the users default avatar.
    if get(u.avatar, "") == "":
        result = "https://cdn.discordapp.com/embed/avatars/$1.png" % [$(u.discriminator.get().parseInt mod 5)]
    else: 
        if u.avatar.get("").startsWith("a_"):
            result = endpointAvatarAnimated(u.id, get(u.avatar, ""))
        else:
            result = endpointAvatar(u.id, get(u.avatar, ""))

proc stripMentions*(msg: Message): string {.gcsafe.} =  
    ## Strips all user mentions from a message
    ## and replaces them with plaintext
    ##
    ## e.g: <@1901092738173> -> @Username#1234
    if msg.mentions.len == 0: return msg.content

    result = msg.content

    for user in msg.mentions:
        let regex = re("(<@!?" & user.id & ">)")
        result = result.replace(regex, "@" & $user)

proc stripEveryoneMention*(msg: Message): string {.gcsafe.} =
    ## Strips a message of any @everyone and @here mention
    if not msg.mention_everyone: return msg.content
    result = msg.content.replace("@everyone", "").replace("@here", "")

proc newChannelParams*(name, topic: string = "",
                       position: int = 0,
                       bitrate: int = 48,
                       userlimit: int = 0): ChannelParams {.gcsafe, inline.} =
    ## Initialises a new ChannelParams object
    ## for altering channel settings.
    result = ChannelParams(
        name: name,
        position: position,
        topic: topic,
        bitrate: bitrate,
        user_limit: userlimit)

proc newGuildParams*(name, region, afkchan: string = "", 
                     verlvl: int = 0,
                     defnotif: int = 0,
                     afktim: int = 0,
                     icon: string = "",
                     ownerid: string = "",
                     splash: string = ""): GuildParams {.gcsafe, inline.} =
    ## Initialises a new GuildParams object
    ## for altering guild settings.
    result = GuildParams(
        name: name,
        region: region,
        verification_level: verlvl,
        default_message_notifications: defnotif,
        afk_channel_id: afkchan,
        afk_timeout: afktim,
        icon: icon,
        owner_id: ownerid,
        splash: splash
    )

proc newGuildMemberParams*(nick, channelid: string = "",
                          roles: seq[string] = @[],
                          mute: bool = false,
                          deaf: bool = false): GuildMemberParams {.gcsafe, inline.} =
    ## Initialises a new GuildMemberParams object
    ## for altering guild members.
    result = GuildMemberParams(
        nick: nick,
        roles: roles,
        mute: mute,
        deaf: deaf,
        channel_id: channelid
    )

proc newWebhookParams*(content, username, avatarurl: string = "", 
                       tts: bool = false, embeds: seq[Embed]): WebhookParams {.gcsafe, inline.} =
    ## Initialises a new WebhookParams object
    ## for altering webhooks.
    result = WebhookParams( 
        content: content, 
        username: username,
        avatar_url: avatarurl,
        tts: tts,
        embeds: embeds
    )