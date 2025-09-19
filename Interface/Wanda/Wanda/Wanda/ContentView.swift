//
//  ContentView.swift
//  Wanda
//
//  Created by Jonathan Jones on 12/6/24.
//

import AVFoundation
//import Speech
import SwiftUI

//Creates an ID for the Chat message
import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
struct ApiResponse: Hashable, Codable{
    let response:String
}
var chat_id = ""
struct ChatMessage: Identifiable, Equatable {
    let id: UUID = UUID()
    let text: String
    let isUser: Bool
    let timeStamp:String
    let showTimestamp: Bool
    

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id && lhs.text == rhs.text && lhs.timeStamp == rhs.timeStamp
    }
}
struct NoAnimationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.0 : 1.0)  // No scale effect
            .animation(nil, value: configuration.isPressed)  // Disable animation
    }
}

//Manages the chat messages
class ChatViewModel: ObservableObject {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
    @Published var messages: [ChatMessage] = []
    @Published var currentMessage: String = ""
    @Published var response: [ApiResponse] = []
    @Published var isMessageSent: Bool = false
    
    
    
    //    Speech variables
//    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(
//        locale: Locale(identifier: "en-US"))
//    private var recognitionTask: SFSpeechRecognitionTask?
//    private var audioEngine = AVAudioEngine()
//    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

 // Start Up Local Server
    func startFlaskServer() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["/Users/jonathanjones/Desktop/GITHUB_Repo/WANDA-Voice-A.I-Assistant/WANDA/app/Server/local_server.py"]
    
    do {
        try process.run()
        print("Running Flask Server")
    } catch {
        print("Failed to start Flask server: \(error)")
    }
    }

    func convertStringToJSON(_ jsonString: String) -> [String: Any]? {
    guard let data = jsonString.data(using: .utf8) else {
        print("Error: Cannot convert string to data")
        return nil
    }
    
    do {
        if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            return json
        } else {
            print("Error: JSON is not a dictionary")
            return nil
        }
    } catch {
        print("Error: \(error.localizedDescription)")
        return nil
    }
}
    func findCommand(message: String) -> [String: String] {
        let arr: [String] = message.split(separator: " ").map { String($0) }
        let commands = ["open","close","time","custom command"]
        var command_dictionary: [String: String] = [:]
        
        for word in arr {
            let index = binary_search(arr: commands, low: 0, high: commands.count - 1, x: word.lowercased())
            if index != -1 {
                command_dictionary["command"] = commands[index]
                               command_dictionary["query"] = message.replacingOccurrences(of: commands[index], with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "+")
                break
            }
        }
        
        return command_dictionary
    }
    
    func binary_search(arr: [String], low: Int, high: Int, x: String) -> Int {
        if high >= low {
            let mid = (high + low) / 2
            if arr[mid] == x {
                return mid
            } else if arr[low..<mid].contains(x) {
                return binary_search(arr: arr, low: low, high: mid - 1, x: x)
            } else {
                return binary_search(arr: arr, low: mid + 1, high: high, x: x)
            }
        } else {
            return -1
        }
    }
    func fetchAPIResponse(base:String,endpoint: String, completion: @escaping (String) -> Void) {
        guard let url = URL(string: "\(base)\(endpoint)") else {
            print("Invalid URL")
            return
        }

        let task = URLSession.shared.dataTask(with: url) {data, response, error in
            if let error = error {
                print("Error: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                print("No data received")
                return
            }

            if let responseString = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    completion(responseString)
                }
            }
        }

        task.resume()
    }
    func initMessage(){
//        startFlaskServer()
//        setupVoiceInput()
//        WandaVoice().listAvailableVoices()
        let timeStamp = dateFormatter.string(from: Date())
         let message: ChatMessage = ChatMessage(text:"Hello how can I help you today?", isUser: false,timeStamp: timeStamp,showTimestamp:true)
//        WandaVoice().speak(text: message.text)
        messages.append(message)
    }

    func sendMessage() {
        //        Checking if currentMessage is empty
        guard !currentMessage.isEmpty else { return }
        //        Updating and appending message
        let timeStamp = dateFormatter.string(from: Date())
        let message: ChatMessage = ChatMessage(text:currentMessage, isUser: true,timeStamp: timeStamp,showTimestamp:false)
        messages.append(message)
        self.currentMessage = ""
        if self.isMessageSent{
//            stopVoiceInput()
        }
        
        //        Triggering Responses
        var endpoint = "error"
        let message_dictionary = findCommand(message: message.text)
        if let command = message_dictionary["command"], let query = message_dictionary["query"] {
            endpoint = "/\(command)?app=\(message.text.replacingOccurrences(of:command, with: "").trimmingCharacters(in: .whitespaces))"
        }
        print(endpoint)
        if ["open", "close"].contains(message_dictionary["command"]) {
            print("In open area")
            fetchAPIResponse(
                base:"http://127.0.0.1:8000",
                endpoint:
                "\(endpoint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ) { response in
                let responseJSON = self.convertStringToJSON(response)
                let chatMessage = ChatMessage(text: responseJSON?["response"] as! String, isUser: false,timeStamp:self.dateFormatter.string(from: Date()),showTimestamp:false)
//                WandaVoice().speak(text: chatMessage.text)
                self.messages.append(chatMessage)
            }
        }

        else{
            endpoint = "?id=\(chat_id)&user_input=\(message.text.replacingOccurrences(of: " ", with: "+"))"
       fetchAPIResponse(
                base:"http://127.0.0.1:8000/genAI/chat",
                endpoint:
                    //                "\(message.text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                "\(endpoint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
            ) { response in
                let responseJSON = self.convertStringToJSON(response)
                chat_id = responseJSON?["chat_id"] as! String
                let chatMessage = ChatMessage(text: responseJSON?["response"] as! String, isUser: false,timeStamp:self.dateFormatter.string(from: Date()),showTimestamp:false)
//                WandaVoice().speak(text: chatMessage.text)
                self.messages.append(chatMessage)
                
            }
        }
    }
//    func setupVoiceInput(){
//        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
//        print("recognitionRequest")
//
//        let inputNode = audioEngine.inputNode
//        let recordingFormat = inputNode.outputFormat(forBus: 0)
//                inputNode.removeTap(onBus: 0)
//                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
//                    self.recognitionRequest?.append(buffer)
//                }
//
//        audioEngine.prepare()
//    }
//    func startVoiceInput() {
//        
//        self.isMessageSent = true
//        do {
//                    try audioEngine.start()
//                    print("Audio engine started")
//        } catch {
//            print("Audio engine couldn't start: \(error.localizedDescription)")
//        }
//        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest!) {
//            result, error in
//            if let transcriptionResult = result {
//                self.currentMessage = transcriptionResult.bestTranscription.formattedString
//            }
//            if error != nil || result?.isFinal == true {
//                self.audioEngine.stop()
////                inputNode.removeTap(onBus: 0)
//                self.recognitionRequest = nil
//                self.recognitionTask = nil
//            }
//        }
//        
//        
//    }

//    func stopVoiceInput() {
//        audioEngine.stop()
////        recognitionRequest?.endAudio()
//        recognitionRequest = nil
//        recognitionTask = nil
//    }
}

struct ContentView: View {
    @StateObject private var viewModel: ChatViewModel = ChatViewModel()
//    @State private var voiceModel: WandaVoice = WandaVoice()
    @State private var isRecording: Bool = false
    
    var body: some View {
        VStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    ForEach(viewModel.messages) { message in
                        if message.showTimestamp == true{
                            Spacer()
                            Text(message.timeStamp)
                                .foregroundColor(.white)
                                .cornerRadius(10)
                                .frame(
                                    maxWidth: 150,
                                    alignment:
                                        .center
                                )
                                .lineLimit(nil)
                                .id(message.id)
                                
                        }
                        HStack{
                                if message.isUser {
                                    //                            User Message Styling
                                    Spacer()
                                    Text(message.text)
                                        .padding(8)
                                        .background(Color.blue)
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                        .frame(
                                            maxWidth: 150,
                                            alignment:
                                                .trailing
                                        )
                                        .lineLimit(nil)
                                        .id(message.id)
                                } else {
                                    Text(message.text)
                                        .padding(8)
                                        .background(Color.red)
//                                        .background(Color(hex:"#"))
                                        .foregroundColor(.white)
                                        .cornerRadius(10)
                                        .frame(
                                            maxWidth: 150,
                                            alignment:
                                                .leading
                                        )
                                        .lineLimit(nil)
                                        .id(message.id)
                                    Spacer()
                                }
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal,10)
                    }
                }.onChange(of: viewModel.messages) { _ in
                    if let lastMessage = viewModel.messages.last {
                        withAnimation(.easeInOut(duration: 10.0)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }.onAppear(){
                    viewModel.initMessage()
                }
            }.padding(.horizontal,10)
            HStack {
                Button(
                    action: {
                        if isRecording {
                            viewModel.isMessageSent = false
//                            viewModel.stopVoiceInput()
                            print("Stop Voice Input")
                        } else {
//                            viewModel.startVoiceInput()
                            viewModel.isMessageSent = false
                            print("Start Voice Input")
                        }
                        isRecording.toggle()
                    },
                    label: {
                        Image(systemName: isRecording ? "mic.fill" : "mic.slash.fill")
                            .foregroundColor(isRecording ? Color.red : Color.gray)
                    }
                )
                .padding(.horizontal)
                .cornerRadius(50)
                .buttonStyle(NoAnimationButtonStyle())

                TextField("Enter message", text: $viewModel.currentMessage)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                    .background(Color.clear)
                    .border(Color.clear)

                Button(
                    action: { viewModel.sendMessage() },
                    label: {
                        Text("Send")
                    }
                )
                .cornerRadius(50)
            }
            .background(Color.white)
            .cornerRadius(5)
            .padding(.horizontal, 10)
        }.padding(.vertical, 10)
    }
}
#Preview {
    ContentView()

}
