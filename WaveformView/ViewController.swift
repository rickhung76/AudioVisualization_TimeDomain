//
//  ViewController.swift
//  WaveformView
//
//  Created by 黃柏叡 on 2017/8/3.
//  Copyright © 2017年 黃柏叡. All rights reserved.
//

import UIKit
import AVFoundation

class ViewController: UIViewController {

    @IBOutlet weak var waveformView: WaveformView!
    
    @IBOutlet weak var playBtn: UIButton!
    @IBAction func playBtnPressed(_ sender: UIButton) {
        sender.isSelected = !sender.isSelected
        if sender.isSelected {
            self.waveformView.playAudio()
        }
        else {
            self.waveformView.stopAudio()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd(_:)), name: NSNotification.Name.AVPlayerItemDidPlayToEndTime, object: nil)
        
        let filePath = Bundle.main.path(forResource: "testAudio", ofType: "mp3")
        guard filePath != nil else {
            return
        }
        self.waveformView.delegate = self as WaveformViewDelegate
        self.waveformView.audioURL = URL(fileURLWithPath: filePath!)
        self.waveformView.barWidth = 8.0
        self.waveformView.barIntervalWidth = 10.0
        self.waveformView.wavesColor = UIColor.orange
    }
    
    func playerItemDidReachEnd(_ notification: Notification) {
        
        if notification.object as? AVPlayerItem  == self.waveformView.playerItem() {
            self.waveformView.stopAudio()
            self.playBtn.isSelected = false
        }
    }
}

extension ViewController: WaveformViewDelegate {
    func waveformViewWillRender(_ waveformView:WaveformView) {
        print("waveformViewWillRender")
    }
    
    func waveformViewDidRender(_ waveformView:WaveformView) {
        print("waveformViewDidRender")
    }
    
    func waveformViewWillLoad(_ waveformView:WaveformView) {
        print("waveformViewWillLoad")
    }
    
    func waveformViewDidLoad(_ waveformView:WaveformView) {
        print("waveformViewDidLoad")
    }
}
