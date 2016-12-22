import Foundation
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore

private enum ChatInfoTitleButton {
    case search
    case info
    case mute
    case unmute
    
    var title: String {
        switch self {
            case .search:
                return "Search"
            case .info:
                return "Info"
            case .mute:
                return "Mute"
            case .unmute:
                return "Unmute"
        }
    }
}

private func peerButtons(_ peer: Peer) -> [ChatInfoTitleButton] {
    if let _ = peer as? TelegramUser {
        return [.search, .info]
    } else {
        return [.search, .mute]
    }
}

final class ChatInfoTitlePanelNode: ChatTitleAccessoryPanelNode {
    private let separatorNode: ASDisplayNode
    
    private var buttons: [(ChatInfoTitleButton, UIButton)] = []
    
    override init() {
        self.separatorNode = ASDisplayNode()
        self.separatorNode.backgroundColor = UIColor(red: 0.6953125, green: 0.6953125, blue: 0.6953125, alpha: 1.0)
        self.separatorNode.isLayerBacked = true
        
        super.init()
        
        self.backgroundColor = UIColor(0xF5F6F8)
        
        self.addSubnode(self.separatorNode)
    }
    
    override func updateLayout(width: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> CGFloat {
        let panelHeight: CGFloat = 44.0
        
        let updatedButtons: [ChatInfoTitleButton]
        if let peer = interfaceState.peer {
            updatedButtons = peerButtons(peer)
        } else {
            updatedButtons = []
        }
        
        var buttonsUpdated = false
        if self.buttons.count != updatedButtons.count {
            buttonsUpdated = true
        } else {
            for i in 0 ..< updatedButtons.count {
                if self.buttons[i].0 != updatedButtons[i] {
                    buttonsUpdated = true
                    break
                }
            }
        }
        
        if buttonsUpdated {
            for (_, view) in self.buttons {
                view.removeFromSuperview()
            }
            self.buttons.removeAll()
            for button in updatedButtons {
                let view = UIButton()
                view.setTitle(button.title, for: [])
                view.titleLabel?.font = Font.regular(17.0)
                view.setTitleColor(UIColor(0x007ee5), for: [])
                view.setTitleColor(UIColor(0x007ee5).withAlphaComponent(0.7), for: [.highlighted])
                view.addTarget(self, action: #selector(self.buttonPressed(_:)), for: [.touchUpInside])
                self.view.addSubview(view)
                self.buttons.append((button, view))
            }
        }
        
        if !self.buttons.isEmpty {
            let buttonWidth = floor(width / CGFloat(self.buttons.count))
            var nextButtonOrigin: CGFloat = 0.0
            for (_, view) in self.buttons {
                view.frame = CGRect(origin: CGPoint(x: nextButtonOrigin, y: 0.0), size: CGSize(width: buttonWidth, height: panelHeight))
                nextButtonOrigin += buttonWidth
            }
        }
        
        transition.updateFrame(node: self.separatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: panelHeight - UIScreenPixel), size: CGSize(width: width, height: UIScreenPixel)))
        
        return panelHeight
    }
    
    @objc func buttonPressed(_ view: UIButton) {
        for (button, buttonView) in self.buttons {
            if buttonView === view {
                switch button {
                    case .info:
                        self.interfaceInteraction?.openPeerInfo()
                    case .mute:
                        self.interfaceInteraction?.togglePeerNotifications()
                    case .unmute:
                        self.interfaceInteraction?.togglePeerNotifications()
                    case .search:
                        self.interfaceInteraction?.beginMessageSearch()
                }
                break
            }
        }
    }
}