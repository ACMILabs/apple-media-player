//
//  BrokerConfig.swift
//  Player
//
//  Created by Simon Loffler on 6/11/2025.
//


import CocoaMQTT
import SwiftUI

struct BrokerConfig: Equatable {
    var isEnabled: Bool
    var urlString: String            // e.g. mqtt://user:pass@broker.local:1883
    var clientId: String             // unique per device
    var mediaPlayerId: String        // used in topic mediaplayer.{id}
    var postIntervalSeconds: Double  // e.g. 0.5

    static func fromDefaults() -> BrokerConfig {
        BrokerConfig(
            isEnabled: UserDefaults.standard.object(forKey: "xos.broker.enabled") as? Bool ?? false,
            urlString: UserDefaults.standard.string(forKey: "xos.broker.url") ?? "",
            clientId: UserDefaults.standard.string(forKey: "xos.broker.clientId")
                ?? ("xos-\(UUID().uuidString.prefix(8))"),
            mediaPlayerId: UserDefaults.standard.string(forKey: "xos.mediaplayer.id") ?? "1",
            postIntervalSeconds: {
                let v = UserDefaults.standard.double(forKey: "xos.broker.interval")
                return v > 0 ? v : 0.5
            }()
        )
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(isEnabled, forKey: "xos.broker.enabled")
        d.set(urlString, forKey: "xos.broker.url")
        d.set(clientId, forKey: "xos.broker.clientId")
        d.set(mediaPlayerId, forKey: "xos.mediaplayer.id")
        d.set(postIntervalSeconds, forKey: "xos.broker.interval")
    }
}

final class MQTTBrokerPublisher: NSObject, CocoaMQTTDelegate {
    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        print("[Broker]: Connected")
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        // print("[Broker]: Published message: \(message.string ?? "<empty>")")
        print("[Broker]: Published with ID: \(id), to topic: \(message.topic)")
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        print("[Broker]: Published")
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        print("[Broker]: Received: \(message.string ?? "<empty>")")
    }

    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {
        print("[Broker]: Subscribed")
    }

    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {
        print("[Broker]: Subscribed to: \(topics.joined(separator: ", "))")
    }

    func mqttDidPing(_ mqtt: CocoaMQTT) {
        print("[Broker]: Ping")
    }

    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {
        print("[Broker]: Pong")
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: (any Error)?) {
        print("[Broker]: Disconnected")
    }

    private(set) var mqtt: CocoaMQTT?
    private var config: BrokerConfig

    init(config: BrokerConfig) {
        self.config = config
        super.init()
    }

    func update(config: BrokerConfig) {
        guard self.config != config else { return }
        self.config = config
        stop()
        if config.isEnabled { start() }
    }

    func start() {
        guard config.isEnabled, let url = URL(string: config.urlString),
              let host = url.host else { return }

        let port = UInt16(url.port ?? (url.scheme == "mqtts" ? 8883 : 1883))
        let clientID = config.clientId

        let m = CocoaMQTT(clientID: clientID, host: host, port: port)
        m.username = url.user
        m.password = url.password
        m.keepAlive = 30
        m.autoReconnect = true
        m.autoReconnectTimeInterval = 2
        m.enableSSL = (url.scheme == "mqtts")
        m.delegate = self
        mqtt = m
        _ = m.connect()
    }

    func stop() {
        mqtt?.disconnect()
        mqtt = nil
    }

    // Publish JSON to mediaplayer.{id}
    func publishStatus(_ payload: [String: Any]) {
        guard let mqtt else { return }
        let topic = "mediaplayer.\(config.mediaPlayerId)"
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else { return }

        mqtt.publish(topic, withString: json, qos: .qos1, retained: false)
    }
}
