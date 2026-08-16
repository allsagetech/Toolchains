<#
Toolchains
Copyright (c) 2026 AllSageTech
SPDX-License-Identifier: MPL-2.0
#>

class TlcSemanticVersion : System.IComparable {
	[int]$Major = 0
	[int]$Minor = 0
	[int]$Patch = 0
	[int]$Build = 0

	hidden Init([string]$Tag, [string]$Pattern) {
		if ([string]::IsNullOrWhiteSpace($Tag) -or [string]::IsNullOrWhiteSpace($Pattern) -or $Tag -notmatch $Pattern) {
			throw "invalid semantic version '$Tag'"
		}
		$this.Major = if ($Matches[1]) { $Matches[1] } else { 0 }
		$this.Minor = if ($Matches[2]) { $Matches[2] } else { 0 }
		$this.Patch = if ($Matches[3]) { $Matches[3] } else { 0 }
		$this.Build = if ($Matches[4]) { [Regex]::Replace("$($Matches[4])", '[^0-9]+', '') } else { 0 }
	}

	TlcSemanticVersion([string]$Tag, [string]$Pattern) {
		$this.Init($Tag, $Pattern)
	}

	TlcSemanticVersion([string]$Version) {
		$this.Init($Version, '^([0-9]+)\.([0-9]+)\.([0-9]+)([+.][0-9]+)?$')
	}

	TlcSemanticVersion() { }

	[bool] LaterThan([object]$Obj) {
		return $this.CompareTo($Obj) -lt 0
	}

	[int] CompareTo([object]$Obj) {
		if ($null -eq $Obj -or $Obj -isnot $this.GetType()) {
			$otherType = if ($null -eq $Obj) { '<null>' } else { $Obj.GetType() }
			throw "cannot compare types $otherType and $($this.GetType())"
		} elseif ((($comparison = $Obj.Major.CompareTo($this.Major)) -ne 0) -or (($comparison = $Obj.Minor.CompareTo($this.Minor)) -ne 0) -or (($comparison = $Obj.Patch.CompareTo($this.Patch)) -ne 0)) {
			return $comparison
		}
		return $Obj.Build.CompareTo($this.Build)
	}

	[bool] Equals([object]$Obj) {
		return $Obj -is $this.GetType() -and $Obj.Major -eq $this.Major -and $Obj.Minor -eq $this.Minor -and $Obj.Patch -eq $this.Patch -and $Obj.Build -eq $this.Build
	}

	[string] ToString() {
		return "$($this.Major).$($this.Minor).$($this.Patch)$(if ($this.Build) { "+$($this.Build)" })"
	}
}
