// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

import SwiftUI

struct AboutView: View {
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("About")
                    .font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // App info
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Jam AUv3")
                            .font(.title2.bold())
                        Text("Version \(appVersion)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        Text("NINJAM client for iOS, iPadOS, and macOS")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Privacy
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Privacy")
                            .font(.headline)
                        Text("This app does not collect, store, or share any personal data. Audio is transmitted directly to the NINJAM or Icecast server you connect to. No analytics or tracking is used.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    // Acknowledgements
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open Source Licenses")
                            .font(.headline)

                        ForEach(licenses) { license in
                            DisclosureGroup {
                                Text(license.text)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(license.name)
                                        .font(.callout.bold())
                                    Text(license.copyright)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
        .background(Color(nsColor: .windowBackgroundColor))
        #else
        .background(Color(uiColor: .systemBackground))
        #endif
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}

// MARK: - License Data

private struct LicenseEntry: Identifiable {
    let id: String
    let name: String
    let copyright: String
    let text: String
}

private let licenses: [LicenseEntry] = [
    LicenseEntry(
        id: "swift-ogg",
        name: "swift-ogg",
        copyright: "Copyright (c) 2024 Readdle Inc.",
        text: """
        MIT License

        Copyright (c) 2024 Readdle Inc.

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    ),
    LicenseEntry(
        id: "swift-vorbis",
        name: "swift-vorbis",
        copyright: "Copyright (c) 2024 Readdle Inc.",
        text: """
        MIT License

        Copyright (c) 2024 Readdle Inc.

        Permission is hereby granted, free of charge, to any person obtaining a copy \
        of this software and associated documentation files (the "Software"), to deal \
        in the Software without restriction, including without limitation the rights \
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell \
        copies of the Software, and to permit persons to whom the Software is \
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all \
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR \
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, \
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE \
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER \
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE \
        SOFTWARE.
        """
    ),
    LicenseEntry(
        id: "libogg",
        name: "libogg",
        copyright: "Copyright (c) 2002, Xiph.org Foundation",
        text: """
        Copyright (c) 2002, Xiph.org Foundation

        Redistribution and use in source and binary forms, with or without modification, \
        are permitted provided that the following conditions are met:

        - Redistributions of source code must retain the above copyright notice, this \
        list of conditions and the following disclaimer.

        - Redistributions in binary form must reproduce the above copyright notice, this \
        list of conditions and the following disclaimer in the documentation and/or other \
        materials provided with the distribution.

        - Neither the name of the Xiph.org Foundation nor the names of its contributors \
        may be used to endorse or promote products derived from this software without \
        specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND \
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED \
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. \
        IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, \
        INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED \
        TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR \
        BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
        CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN \
        ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH \
        DAMAGE.
        """
    ),
    LicenseEntry(
        id: "libvorbis",
        name: "libvorbis",
        copyright: "Copyright (c) 2002-2020 Xiph.org Foundation",
        text: """
        Copyright (c) 2002-2020 Xiph.org Foundation

        Redistribution and use in source and binary forms, with or without modification, \
        are permitted provided that the following conditions are met:

        - Redistributions of source code must retain the above copyright notice, this \
        list of conditions and the following disclaimer.

        - Redistributions in binary form must reproduce the above copyright notice, this \
        list of conditions and the following disclaimer in the documentation and/or other \
        materials provided with the distribution.

        - Neither the name of the Xiph.org Foundation nor the names of its contributors \
        may be used to endorse or promote products derived from this software without \
        specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND \
        ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED \
        WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. \
        IN NO EVENT SHALL THE FOUNDATION OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, \
        INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED \
        TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR \
        BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN \
        CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN \
        ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH \
        DAMAGE.
        """
    ),
]
