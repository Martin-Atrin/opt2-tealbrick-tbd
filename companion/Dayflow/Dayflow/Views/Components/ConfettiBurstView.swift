//
//  ConfettiBurstView.swift
//  Dayflow
//
//  Lightweight celebratory burst used by app surfaces.
//

import SwiftUI
import TBDDesign

struct ConfettiBurstView: View {
  let trigger: Int

  // Kit tones (teal, moss, wood, brick, stone) in place of the old rainbow.
  private let colors: [Color] = [
    TBDColor.toneTeal,
    TBDColor.toneBrick,
    TBDColor.toneMoss,
    TBDColor.toneWood,
    TBDColor.tealInk,
    TBDColor.toneStone,
    TBDColor.brick,
    TBDColor.teal,
    TBDColor.toneWoodInk,
    TBDColor.toneMossInk,
  ]
  private let confettiCount = 60

  var body: some View {
    ZStack {
      ForEach(0..<confettiCount, id: \.self) { index in
        ConfettiPiece(
          color: colors[index % colors.count],
          trigger: trigger
        )
      }
    }
    .allowsHitTesting(false)
  }
}

private struct ConfettiPiece: View {
  let color: Color
  let trigger: Int
  @State private var offset: CGSize = .zero
  @State private var rotation: Double = 0
  @State private var opacity: Double = 0

  var body: some View {
    RoundedRectangle(cornerRadius: TBDKit.radiusSwatch)
      .fill(color)
      .frame(width: 6, height: 10)
      .rotationEffect(.degrees(rotation))
      .offset(offset)
      .opacity(opacity)
      .onChange(of: trigger) {
        let xStart = Double.random(in: -60...60)
        let xBurst = Double.random(in: -220...220)
        let xFall = Double.random(in: -340...340)
        let yBurst = Double.random(in: -30...50)
        let yFall = Double.random(in: 200...360)
        let spinBurst = Double.random(in: -120...120)
        let spinFall = spinBurst + Double.random(in: -240...240)

        offset = CGSize(width: xStart, height: -6)
        rotation = 0
        opacity = 1

        withAnimation(TBDMotion.spring) {
          offset = CGSize(width: xBurst, height: yBurst)
          rotation = spinBurst
        }

        withAnimation(.easeInOut(duration: 1.6).delay(0.3)) {
          offset = CGSize(width: xFall, height: yFall)
          rotation = spinFall
        }

        withAnimation(TBDMotion.gentle.delay(1.6)) {
          opacity = 0
        }
      }
  }
}
