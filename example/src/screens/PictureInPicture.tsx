import { useRef, useState } from 'react'
import { Pressable, StyleSheet, Text, View } from 'react-native'
import { VideoView, type VideoViewRef } from 'react-native-nitro-video'

const SOURCE =
  'https://storage.googleapis.com/exoplayer-test-media-0/BigBuckBunny_320x180.mp4'

export function PictureInPicture() {
  const ref = useRef<VideoViewRef>(null)
  const [isActive, setIsActive] = useState(false)
  const [log, setLog] = useState('')

  return (
    <View style={styles.container}>
      <VideoView
        ref={ref}
        source={SOURCE}
        autoplay
        muted
        loop
        allowsPictureInPicture
        style={styles.video}
        onPictureInPictureChange={setIsActive}
      />

      <View style={styles.row}>
        <Pressable
          onPress={async () => {
            try {
              await ref.current?.startPictureInPicture()
              setLog('startPictureInPicture resolved')
            } catch (error) {
              setLog(`rejected: ${String(error)}`)
            }
          }}
          style={styles.button}
        >
          <Text style={styles.buttonText}>start PiP</Text>
        </Pressable>
        <Pressable
          onPress={() => ref.current?.stopPictureInPicture()}
          style={styles.button}
        >
          <Text style={styles.buttonText}>stop PiP</Text>
        </Pressable>
      </View>

      <Text style={styles.info}>
        PiP active: {String(isActive)} {log ? `· ${log}` : ''}
      </Text>
      <Text style={styles.note}>
        Also try backgrounding the app — the playing video pops into PiP.
      </Text>
    </View>
  )
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    gap: 12,
    padding: 12,
  },
  video: {
    aspectRatio: 16 / 9,
    backgroundColor: '#000',
    width: '100%',
  },
  row: {
    flexDirection: 'row',
    gap: 8,
  },
  button: {
    backgroundColor: '#5856d6',
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  buttonText: {
    color: '#fff',
    fontSize: 13,
  },
  info: {
    color: '#9f9',
    fontFamily: 'Menlo',
    fontSize: 12,
  },
  note: {
    color: '#999',
    fontSize: 12,
  },
})
