// Copyright OpenFX and contributors to the OpenFX project.
// SPDX-License-Identifier: BSD-3-Clause

#if canImport(AppKit)
import ExtensionKit
import SwiftUI

/// The system's list of your app's extensions, where people approve, enable and
/// disable them (`EXAppExtensionBrowserViewController`). Extensions that ship in
/// other apps stay disabled until enabled here or in System Settings.
@available(macOS 26.0, *)
public struct OFXExtensionBrowser: NSViewControllerRepresentable {
  public init() {}

  public func makeNSViewController(context: Context) -> EXAppExtensionBrowserViewController {
    EXAppExtensionBrowserViewController()
  }

  public func updateNSViewController(_ controller: EXAppExtensionBrowserViewController, context: Context) {}
}
#endif
