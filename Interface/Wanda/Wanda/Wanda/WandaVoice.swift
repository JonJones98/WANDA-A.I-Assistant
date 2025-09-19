import AVFoundation
import Foundation
import AVKit
import Speech

class WandaVoice: NSObject, AVSpeechSynthesizerDelegate{
    let synthesizer = AVSpeechSynthesizer()
    override init() {
            super.init()
            synthesizer.delegate = self
        
        }
    
    func listAvailableVoices() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        for voice in voices {
            print("Voice identifier: \(voice.identifier), Language: \(voice.language), Name: \(voice.name)")
        }
    }
    
    func speak(text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Ava")
        utterance.rate = 0.5
        synthesizer.speak(utterance)
        print(synthesizer.isSpeaking)
    }
}
