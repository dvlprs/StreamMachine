_ = require "underscore"

module.exports = class HLSIndex
    constructor: (@stream,@tz,@group) ->
        @_shouldRun = false
        @_running   = false

        @_segment_idx       = {}
        @_segments          = []
        @_segment_length    = null

        @_header = null
        @_index  = null

        @_short_header   = null
        @_short_index    = null

    #----------

    loadSnapshot: (snapshot) ->
        if snapshot
            @_segments          = snapshot.segments
            @_segment_duration  = snapshot.segment_duration
            @queueIndex()

    #----------

    queueIndex: ->
        @_shouldRun = true
        @_runIndex()

    #----------

    _runIndex: ->
        return false if @_running || !@stream

        @_running   = true
        @_shouldRun = false

        _after = =>
            # -- should we run again? -- #

            @_running = false
            @_runIndex() if @_shouldRun

        # clone the segments array, in case it changes while we're running
        segs = @_segments.slice(0)

        if segs.length < 3
            # not enough buffer for a playlist yet
            @header = null
            @_index  = null

            _after()
            return false

        # -- Determine Short Index Start -- #

        _short_length   = 120 / @_segment_duration
        _short_start    = segs.length - 1 - _short_length
        _short_start    = 2 if _short_start < 2

        # -- build our header -- #

        head = new Buffer """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:#{@_segment_duration}
        #EXT-X-MEDIA-SEQUENCE:#{segs[2].id}
        #EXT-X-DISCONTINUITY-SEQUENCE:#{segs[2].discontinuitySeq}
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-START:TIME-OFFSET=-45

        """

        short_head = new Buffer """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:#{@_segment_duration}
        #EXT-X-MEDIA-SEQUENCE:#{segs[_short_start].id}
        #EXT-X-DISCONTINUITY-SEQUENCE:#{segs[_short_start].discontinuitySeq}
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-START:TIME-OFFSET=-45

        """

        # run through segments and build the index
        # We skip the first three segments for the index, but we'll use
        # segment #2 for our next ts

        idx_segs    = []
        idx_length  = 0

        # -- loop through remaining segments -- #

        dseq = segs[1].discontinuitySeq

        for seg,i in segs[2..]
            # is the segment where we expect it in the timeline?
            has_disc = !(seg.discontinuitySeq == dseq)

            b = new Buffer """
            #{ if has_disc then "#EXT-X-DISCONTINUITY\n" else "" }#EXTINF:#{seg.duration / 1000},
            #EXT-X-PROGRAM-DATE-TIME:#{@tz(seg.ts_actual,"%FT%T.%3N%:z")}
            /#{@stream.key}/ts/#{seg.id}.#{@stream.opts.format}
            """

            idx_length += b.length

            idx_segs.push b

            dseq = seg.discontinuitySeq

        # -- build the segment map -- #

        seg_map = {}
        for s in segs
            seg_map[ s.id ] = s

        # -- set these as active -- #

        @_header        = head
        @_index         = idx_segs
        @_index_length  = idx_length

        @_short_header  = short_head
        @_short_index   = idx_segs[ _short_start.. ]

        short_length    = 0
        short_length += b.length for b in @_short_index

        @_short_length  = short_length

        @_segment_idx   = seg_map

        _after()

    #----------

    short_index: (session,cb) ->
        session = if session then new Buffer(session+"\n") else new Buffer("\n")

        if !@_short_header
            return cb null, null

        writer = new HLSIndex.Writer @_short_header, @_short_index, @_short_length, session
        cb null, writer

    #----------

    index: (session,cb) ->
        session = if session then new Buffer(session+"\n") else new Buffer("\n")

        if !@_header
            return cb null, null

        writer = new HLSIndex.Writer @_header, @_index, @_index_length, session
        cb null, writer

    #----------

    pumpSegment: (rewinder,id,cb) ->
        # given a segment id, look the segment up in our store to get start ts
        # and duration, then ask the RewindBuffer for the appropriate data

        if s = @_segment_idx[ Number(id) ]
            # valid segment...
            dur = @stream.secsToOffset s.duration / 1000
            @stream.pumpFrom rewinder, s.ts_actual, dur, false, cb
        else
            cb "Segment not found in index."

    #----------

    class @Writer extends require("stream").Readable
        constructor: (@header,@index,@ilength,@session) ->
            super

            @_sentHeader = false
            @_idx = 0

            # determine total length
            @_length = @header.length + @ilength + (@session.length * @index.length)

        length: ->
            @_length

        _read: (size) ->
            sent = 0

            if !@_sentHeader
                @push @header
                @_sentHeader = true
                sent += @header.length

            loop
                @push @index[@_idx]
                @push @session

                sent += @index[@_idx].length
                sent += @session.length

                @_idx += 1

                break if (sent > size) || @_idx == @index.length

            if @_idx == @index.length
                @push null
