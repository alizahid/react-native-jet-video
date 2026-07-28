import { useState } from 'react'
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native'
import { VideoView } from 'react-native-jet-video'

const SOURCES = {
  mp4: 'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4',
  hls: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8',
} as const

const RESIZE_MODES = ['cover', 'contain', 'stretch'] as const

export function BasicPlayback() {
  const [format, setFormat] = useState<keyof typeof SOURCES>('mp4')
  const [resizeMode, setResizeMode] =
    useState<(typeof RESIZE_MODES)[number]>('cover')
  const [muted, setMuted] = useState(true)
  const [log, setLog] = useState<string[]>([])

  const append = (line: string) => {
    setLog((prev) => [...prev.slice(-19), line])
  }

  return (
    <View style={styles.container}>
      <VideoView
        source={SOURCES[format]}
        autoplay
        muted={muted}
        loop
        resizeMode={resizeMode}
        style={styles.video}
        onLoad={(event) =>
          append(
            `load: ${event.duration.toFixed(1)}s ${event.naturalSize.width}x${event.naturalSize.height}${event.isLive ? ' live' : ''}`
          )
        }
        onProgress={(event) =>
          append(
            `progress: ${event.currentTime.toFixed(1)}s (buffered to ${event.bufferedPosition.toFixed(1)}s)`
          )
        }
        onEnd={() => append('end')}
        onError={(event) => append(`error: ${event.code} ${event.message}`)}
        onPlaybackStateChange={(event) =>
          append(`state: ${event.status} (${event.reason})`)
        }
      />

      <View style={styles.row}>
        {(Object.keys(SOURCES) as (keyof typeof SOURCES)[]).map((key) => (
          <Pressable
            key={key}
            onPress={() => setFormat(key)}
            style={[styles.button, format === key && styles.buttonActive]}
          >
            <Text style={styles.buttonText}>{key.toUpperCase()}</Text>
          </Pressable>
        ))}
        {RESIZE_MODES.map((mode) => (
          <Pressable
            key={mode}
            onPress={() => setResizeMode(mode)}
            style={[styles.button, resizeMode === mode && styles.buttonActive]}
          >
            <Text style={styles.buttonText}>{mode}</Text>
          </Pressable>
        ))}
        <Pressable
          onPress={() => setMuted((value) => !value)}
          style={[styles.button, muted && styles.buttonActive]}
        >
          <Text style={styles.buttonText}>muted</Text>
        </Pressable>
      </View>

      <ScrollView style={styles.log}>
        {log.map((line, index) => (
          <Text
            // biome-ignore lint/suspicious/noArrayIndexKey: append-only log
            key={index}
            style={styles.logLine}
          >
            {line}
          </Text>
        ))}
      </ScrollView>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  row: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    padding: 12,
  },
  button: {
    backgroundColor: '#333',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  buttonActive: {
    backgroundColor: '#5856d6',
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
  },
  log: {
    backgroundColor: '#111',
    flex: 1,
    padding: 12,
  },
  logLine: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 11,
  },
})
