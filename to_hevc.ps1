# Ensure console output uses UTF-8 encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Check if ffmpeg and ffprobe are installed and available in the PATH
if (!(Get-Command ffmpeg -ErrorAction SilentlyContinue) -or !(Get-Command ffprobe -ErrorAction SilentlyContinue)) {
    Write-Host "Error: ffmpeg or ffprobe not found. Please install them and add to PATH." -ForegroundColor Red
    exit
}

# Add help function
function Show-Help {
    Write-Host "Usage: script.ps1 [-S] [-crf=<value>] [-preset=<value>] [-acodec=<value>] [files]"
    Write-Host "-S             Save original files after conversion."
    Write-Host "-crf=<value>    Set the CRF (Constant Rate Factor) value (e.g., -crf=20)."
    Write-Host "-preset=<value> Set the video preset (e.g., -preset=slow)."
    Write-Host "-acodec=<value> Set the audio codec (e.g., -acodec=libopus)."
    Write-Host "files           Optional list of files to process. If omitted, all video files in the current directory will be processed."
    exit
}

# Check for help argument
if ($args -contains "-h" -or $args -contains "-help" -or $args -contains "--help") {
    Show-Help
}

# Default CRF (Constant Rate Factor) value
$crf = 20.0
$audioCodec = "libopus"
$audioBitrate = "192k"
$videoPreset = "slow"

# Flag to determine if the original files should be saved
$saveOriginals = $false
# Files to process, initially empty
$files = @()

# Parse command line arguments
foreach ($arg in $args) {
    if ($arg -match '^-S$') {
        $saveOriginals = $true
    } elseif ($arg -match '^-crf=(\d+(\.\d+)?)$') {
        $crf = [double]$matches[1]
    } elseif ($arg -match '^-preset=(\w+)$') {
        $videoPreset = $matches[1]
    } elseif ($arg -match '^-acodec=(\w+)$') {
        $audioCodec = $matches[1]
    } else {
        $files += $arg
    }
}

$sao = "sao=1"
if ($crf -le 16) {
    $sao = "no-sao=1"
} elseif ($crf -le 20) {
    $sao = "limit-sao=1"
}

# Encoder settings for high-quality HEVC conversion
$encoder = @("-x265-params", "aq-mode=3:crf=$($crf):ref=4:bframes=8:deblock=-1,-1:$sao")
$encoder

# Initialize variables for tracking space savings and processed file count
$totalSpaceSavedMB = 0
$processedFilesCount = 0

# List of file extensions to exclude from processing
$excludedExtensions = @(
    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tiff', '.webp',          # Image files
    '.mp3', '.wav', '.flac', '.aac', '.ogg', '.wma', '.m4a', '.mka',    # Audio files
    '.txt', '.doc', '.docx', '.pdf', '.rtf', '.odt',                    # Text files
    '.srt', '.sub', '.ass', '.vtt'                                      # Subtitle files
)

# Determine files to process
$filesToProcess = if ($files.Count -eq 0) {
    # If no files specified, process all video files in the current directory
    Get-ChildItem -File | Where-Object { $excludedExtensions -notcontains $_.Extension.ToLower() }
} else {
    # Validate specified files and exclude non-existent ones
    $files | ForEach-Object {
        try {
            Get-Item -Path $_
        } catch {
            Write-Host "Error: File '$_' does not exist or cannot be accessed." -ForegroundColor Red
            $null
        }
    } | Where-Object { $_ -and ($excludedExtensions -notcontains $_.Extension.ToLower()) }
}

foreach ($file in $filesToProcess) {
    # Use ffprobe to check if the file contains a video stream
    $videoStreamCheck = ffprobe -v quiet -select_streams v -show_entries stream=codec_type -of csv=p=0 $file.FullName
    if (-not $videoStreamCheck -or $videoStreamCheck -notmatch "video") {
        Write-Host "Skipping non-video file: $($file.Name)" -ForegroundColor Yellow
        continue
    }

    # Check the number of video streams in the file
    $videoStreamIndexes = ffprobe -v quiet -select_streams v -show_entries stream=index -of csv=p=0 $file.FullName
    if (-not $videoStreamIndexes) {
        Write-Host "Skipping file: $($file.Name) due to no video streams found." -ForegroundColor Yellow
        continue
    }

    $videoStreamIndexesArray = $videoStreamIndexes.TrimEnd(',').Split(",")
    if ($videoStreamIndexesArray.Count -gt 1) {
        Write-Host "Skipping file: $($file.Name) because it has more than one video stream." -ForegroundColor Yellow
        continue
    }

    # Retrieve the codec information for the video stream using ffprobe
    $codecInfo = ffprobe -v quiet -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 $file.FullName

    # Check if the video codec is not HEVC, VP9, AV1
    if ($codecInfo -match "hevc|vp9|av01") {
        Write-Host "Skipping file (already HEVC, VP9, or AV1): $($file.Name)" -ForegroundColor Yellow
        continue
    }

    Write-Host "Converting file: $($file.Name)" -ForegroundColor Green

    # Define the temporary output file path
    $outputFile = "$($file.DirectoryName)\$($file.BaseName)_HEVC$($file.Extension)"
    ffmpeg -y -i $file.FullName -c:v libx265 -preset $videoPreset $encoder -pix_fmt yuv420p10le -c:a $audioCodec -b:a $audioBitrate -c:s copy -c:d copy -map 0 -hide_banner $outputFile

    # Check if the conversion was successful by comparing durations
    $originalDuration = ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $file.FullName
    $outputDuration = ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $outputFile
    if ([math]::Abs($originalDuration - $outputDuration) -gt 1) {
        Write-Host "Error: Output file duration mismatch, keeping the original file: $($file.Name)" -ForegroundColor Red
        Remove-Item $outputFile -Force
        continue
    }

    Write-Host "Conversion completed: $outputFile" -ForegroundColor Green

    # Calculate the space savings
    $originalSizeMB = [math]::Round(($file.Length / 1MB), 2)
    $outputFileInfo = Get-Item -LiteralPath $outputFile
    $outputSizeMB = [math]::Round(($outputFileInfo.Length / 1MB), 2)
    $spaceSavedMB = [math]::Round(($originalSizeMB - $outputSizeMB), 2)

    Write-Host "Original Size: $originalSizeMB MB, Converted Size: $outputSizeMB MB, Space Saved: $spaceSavedMB MB" -ForegroundColor Cyan
    $totalSpaceSavedMB += $spaceSavedMB
    $processedFilesCount++

    # Report total space saved and processed files count
    $roundedTotalSpaceSavedMB = [math]::Round($totalSpaceSavedMB, 2)
    Write-Host "Total space saved: $roundedTotalSpaceSavedMB MB (Processed files: $processedFilesCount)" -ForegroundColor Cyan

    # Remove the original file unless the -Save switch is specified
    if (-not $saveOriginals) {
        Remove-Item -LiteralPath $file.FullName -Force
        Rename-Item -LiteralPath $outputFile -NewName $file.Name
    }
}

Write-Host "All files processed." -ForegroundColor Green
