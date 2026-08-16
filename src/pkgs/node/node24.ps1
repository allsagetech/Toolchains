<# Toolchains | SPDX-License-Identifier: MPL-2.0 #>

Initialize-TlcNodePackage -Major 24 -BuildRevision 1 -NpmVersion '12.0.2' `
	-NpmExpectedSha512 'b885e890b9418fa1693544d05f53e64f9a73ec194837d4258b15fecdd692347b1dd2a517b1b0cbaf9d31cd8e92c3b70956bd2ecc72833a57b4b3098f5bfa7943' `
	-NpmDependencyOverlays @{
		'brace-expansion' = @{
			Version = '5.0.9'
			ExpectedSha512 = '49c43822ebc8105d533253fb66dfaf8c9ffff7394f6f64837315b13376e4f2ceade8619d27b28ed5d09c4e274e3c929e3d6df42c4ff6713ef00b23e1a3dfd6c6'
		}
		'ip-address' = @{
			Version = '10.5.0'
			ExpectedSha512 = '4794a754b26681862f7f6176660c120677a5cf91b8ab9031202dbbec60df51a35bad928d00d7010bb447a9861e3e5b337f8901a2556425ab86d198c71c5879e6'
		}
	}
