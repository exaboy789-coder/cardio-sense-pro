%% =========================================================
%  CardioSense Pro - All-in-One ECG Diagnostic Workstation
%  ES197 Medical Device Project | Warwick Clinical Solutions
%  ---------------------------------------------------------
%  HOW TO RUN:  Simply type  CardioSensePro  in the MATLAB
%               Command Window, or press Run in the editor.
%
%  ACQUISITION MODES (set on line ~40):
%    'file'    - Load a pre-recorded CSV (use for testing)
%    'arduino' - Live 20-second recording from AD8232/Arduino
%
%  ARDUINO WIRING (AD8232 --> Arduino Uno):
%    3.3V    --> 3.3V
%    GND     --> GND
%    OUTPUT  --> A0   (analogue ECG signal)
%    LO+     --> D10  (leads-off detection)
%    LO-     --> D11  (leads-off detection)
%
%  ARDUINO SKETCH (upload separately, see bottom of this file):
%    Baud: 9600 | Sampling: ~500 Hz (2ms delay per loop)
%    Sends: analogRead(A0) as integer, one value per line
% ==========================================================

function CardioSensePro()

    %% ---- USER SETTINGS ------------------------------------
    ACQ_MODE    = 'file';       % 'file' or 'arduino'
    COM_PORT    = 'COM3';       % Change to your Arduino port
    %                             Windows: 'COM3', 'COM4', etc.
    %                             Mac/Linux: '/dev/ttyUSB0', etc.
    BAUD_RATE   = 9600;
    FS          = 500;          % Sampling frequency (Hz)
    DURATION    = 20;           % Recording duration (seconds)
    F_LOW       = 0.5;          % Band-pass lower cutoff (Hz)
    F_HIGH      = 40;           % Band-pass upper cutoff (Hz)
    F_NOTCH     = 50;           % UK mains notch frequency (Hz)
    %% -------------------------------------------------------

    %% ---- STEP 1: DATA ACQUISITION -------------------------
    switch lower(ACQ_MODE)

        case 'file'
            [file, path] = uigetfile('*.csv', 'Select ECG CSV File');
            if isequal(file, 0)
                errordlg('No file selected.','CardioSense Pro'); return;
            end
            T        = readtable(fullfile(path, file));
            time_raw = T.Time_Seconds;
            ecg_raw  = T.Raw;
            FS       = round(1 / mean(diff(time_raw)));

        case 'arduino'
            fprintf('Connecting to Arduino on %s ...\n', COM_PORT);
            try
                a = serialport(COM_PORT, BAUD_RATE);
                configureTerminator(a, "LF");
                flush(a);
            catch
                errordlg(sprintf('Cannot open %s. Check port & Arduino is connected.', COM_PORT), ...
                         'CardioSense Pro'); return;
            end

            N        = FS * DURATION;
            ecg_raw  = zeros(N, 1);
            time_raw = (0:N-1)' / FS;

            fprintf('Recording for %d seconds ...\n', DURATION);
            wb = waitbar(0, 'Recording ECG from Arduino...', ...
                         'Name', 'CardioSense Pro');
            for i = 1:N
                line = readline(a);
                val  = str2double(strtrim(line));
                if isnan(val); val = 0; end
                % Convert 10-bit ADC (0-1023) to voltage (0-3.3V)
                ecg_raw(i) = (val / 1023) * 3.3;
                if mod(i, 100) == 0
                    waitbar(i/N, wb, sprintf('Recording... %.0f%%', 100*i/N));
                end
            end
            close(wb);
            clear a;
            fprintf('Recording complete.\n');

        otherwise
            error('ACQ_MODE must be ''file'' or ''arduino''.');
    end

    %% ---- STEP 2: SIGNAL FILTERING -------------------------

    % 2a. Notch filter: remove 50 Hz UK powerline interference
    wo              = F_NOTCH / (FS/2);
    bw              = wo / 35;
    [b_n, a_n]      = iirnotch(wo, bw);
    ecg_notched     = filtfilt(b_n, a_n, ecg_raw);

    % 2b. Band-pass filter: 0.5-40 Hz
    %     Removes baseline wander (<0.5 Hz) and EMG noise (>40 Hz)
    %     Standard per AHA / IEC 60601-2-51
    [b_bp, a_bp]    = butter(4, [F_LOW, F_HIGH] / (FS/2), 'bandpass');
    ecg_filtered    = filtfilt(b_bp, a_bp, ecg_notched);

    %% ---- STEP 3: R-PEAK DETECTION -------------------------
    % Pan-Tompkins inspired approach:
    %   Differentiate -> Square -> Moving-window integrate -> findpeaks

    ecg_diff    = [diff(ecg_filtered); 0];
    ecg_sq      = ecg_diff .^ 2;
    ecg_mwi     = movmean(ecg_sq, round(0.150 * FS));  % 150 ms window

    threshold       = 0.45 * max(ecg_mwi);
    min_rr_samples  = round(0.300 * FS);               % 200 bpm max

    [~, r_cand] = findpeaks(ecg_mwi, ...
                            'MinPeakHeight',   threshold, ...
                            'MinPeakDistance', min_rr_samples);

    % Refine peaks back onto filtered signal (±50 ms search window)
    search_win  = round(0.050 * FS);
    r_locs      = zeros(size(r_cand));
    for k = 1:length(r_cand)
        i1          = max(1, r_cand(k) - search_win);
        i2          = min(length(ecg_filtered), r_cand(k) + search_win);
        [~, lm]     = max(ecg_filtered(i1:i2));
        r_locs(k)   = i1 + lm - 1;
    end

    r_times      = time_raw(r_locs);
    r_amplitudes = ecg_filtered(r_locs);

    %% ---- STEP 4: METRICS ----------------------------------

    if length(r_locs) >= 2
        rr_intervals = diff(r_times);           % seconds
        heart_rate   = 60 / mean(rr_intervals); % bpm
        sdnn_ms      = std(rr_intervals) * 1000;% ms (Stretch Target E1)
    else
        rr_intervals = [];
        heart_rate   = NaN;
        sdnn_ms      = NaN;
    end

    % Signal Quality Index (SQI) - Stretch Target E3
    % Kurtosis-based: clean ECG has sharp QRS -> high kurtosis
    kurt_val = kurtosis(ecg_filtered);
    if kurt_val >= 5
        sqi_label = 'Excellent';
        sqi_color = [0.05 0.65 0.32];
    elseif kurt_val >= 3
        sqi_label = 'Acceptable';
        sqi_color = [0.85 0.55 0.05];
    else
        sqi_label = 'Poor';
        sqi_color = [0.85 0.16 0.16];
    end

    %% ---- STEP 5: GUI LAYOUT --------------------------------

    scr = get(0, 'ScreenSize');
    fw  = min(1320, scr(3) - 40);
    fh  = min(820,  scr(4) - 60);
    fx  = (scr(3) - fw) / 2;
    fy  = (scr(4) - fh) / 2;

    fig = figure('Name', 'CardioSense Pro  |  ECG Diagnostic Workstation', ...
                 'NumberTitle', 'off', ...
                 'Color', [0.10 0.13 0.20], ...
                 'Position', [fx fy fw fh], ...
                 'MenuBar', 'none', ...
                 'ToolBar', 'none', ...
                 'Resize', 'on');

    % ---- Colour palette ----
    C_BG        = [0.10 0.13 0.20];  % dark navy background
    C_PANEL     = [0.14 0.18 0.27];  % slightly lighter panel
    C_ACCENT    = [0.18 0.56 0.90];  % bright blue accent
    C_GREEN     = [0.05 0.75 0.45];  % healthy green
    C_RED       = [0.93 0.28 0.28];  % alert red
    C_TEXT      = [0.90 0.93 0.98];  % near-white text
    C_SUBTEXT   = [0.55 0.62 0.75];  % muted text
    C_RAW       = [0.45 0.52 0.65];  % raw signal colour
    C_FILT      = [0.25 0.72 0.98];  % filtered signal colour
    C_RPEAK     = [0.98 0.38 0.38];  % R-peak marker colour
    C_HRV       = [0.72 0.38 0.95];  % HRV line colour

    % Normalised positions [left bottom width height]
    % Header bar
    uicontrol(fig, 'Style','text', ...
        'Units','normalized', 'Position',[0 0.94 1 0.06], ...
        'BackgroundColor', [0.08 0.11 0.18], ...
        'ForegroundColor', C_TEXT, ...
        'String', '  CardioSense Pro   |   ECG Diagnostic Workstation   |   ES197  |  Warwick Clinical Solutions', ...
        'FontSize', 13, 'FontWeight','bold', 'HorizontalAlignment','left');

    % ---- Metric cards row ----
    card_labels  = {'Heart Rate', 'SDNN (HRV)', 'R-Peaks', 'Signal Quality'};
    card_units   = {'bpm', 'ms', 'detected', ''};

    if ~isnan(heart_rate)
        hr_str = sprintf('%.1f', heart_rate);
        if heart_rate < 60;     hr_col = C_ACCENT;
        elseif heart_rate > 100; hr_col = C_RED;
        else;                   hr_col = C_GREEN;
        end
    else
        hr_str = 'N/A'; hr_col = C_SUBTEXT;
    end

    if ~isnan(sdnn_ms)
        sdnn_str = sprintf('%.1f', sdnn_ms);
    else
        sdnn_str = 'N/A';
    end

    card_values  = {hr_str, sdnn_str, num2str(length(r_locs)), sqi_label};
    card_colours = {hr_col, C_ACCENT, C_GREEN, sqi_color};
    card_x       = [0.01 0.26 0.51 0.76];
    card_w       = 0.23;

    for c = 1:4
        % Card background
        uicontrol(fig, 'Style','text', ...
            'Units','normalized', 'Position',[card_x(c) 0.80 card_w 0.13], ...
            'BackgroundColor', C_PANEL, 'String','');
        % Card title
        uicontrol(fig, 'Style','text', ...
            'Units','normalized', 'Position',[card_x(c)+0.005 0.89 card_w-0.01 0.03], ...
            'BackgroundColor', C_PANEL, ...
            'ForegroundColor', C_SUBTEXT, ...
            'String', card_labels{c}, ...
            'FontSize', 9, 'FontWeight','bold', 'HorizontalAlignment','left');
        % Card value
        uicontrol(fig, 'Style','text', ...
            'Units','normalized', 'Position',[card_x(c)+0.005 0.81 card_w-0.01 0.08], ...
            'BackgroundColor', C_PANEL, ...
            'ForegroundColor', card_colours{c}, ...
            'String', [card_values{c} '  ' card_units{c}], ...
            'FontSize', 20, 'FontWeight','bold', 'HorizontalAlignment','left');
    end

    % ---- Plot 1: Raw ECG ----
    ax1 = axes('Parent', fig, 'Units','normalized', ...
               'Position', [0.05 0.57 0.92 0.21], ...
               'Color', C_PANEL, 'XColor', C_SUBTEXT, 'YColor', C_SUBTEXT, ...
               'GridColor', [0.25 0.30 0.42], 'GridAlpha', 0.5);
    plot(ax1, time_raw, ecg_raw, 'Color', C_RAW, 'LineWidth', 0.9);
    title(ax1, 'Raw ECG Signal', 'Color', C_TEXT, 'FontSize', 10, 'FontWeight','bold');
    xlabel(ax1, 'Time (s)', 'Color', C_SUBTEXT);
    ylabel(ax1, 'Amplitude (V)', 'Color', C_SUBTEXT);
    xlim(ax1, [0 max(time_raw)]); grid(ax1, 'on');

    % ---- Plot 2: Filtered ECG + R-peaks ----
    ax2 = axes('Parent', fig, 'Units','normalized', ...
               'Position', [0.05 0.31 0.92 0.21], ...
               'Color', C_PANEL, 'XColor', C_SUBTEXT, 'YColor', C_SUBTEXT, ...
               'GridColor', [0.25 0.30 0.42], 'GridAlpha', 0.5);
    plot(ax2, time_raw, ecg_filtered, 'Color', C_FILT, 'LineWidth', 1.1); hold(ax2,'on');
    plot(ax2, r_times, r_amplitudes, 'v', ...
         'Color', C_RPEAK, 'MarkerFaceColor', C_RPEAK, 'MarkerSize', 7);
    hold(ax2,'off');
    title(ax2, sprintf('Filtered ECG + R-peaks  |  HR: %.1f bpm  |  %d beats detected', ...
          heart_rate, length(r_locs)), ...
          'Color', C_TEXT, 'FontSize', 10, 'FontWeight','bold');
    xlabel(ax2, 'Time (s)', 'Color', C_SUBTEXT);
    ylabel(ax2, 'Amplitude (V)', 'Color', C_SUBTEXT);
    xlim(ax2, [0 max(time_raw)]); grid(ax2, 'on');
    legend(ax2, 'Filtered ECG', 'R-peaks', ...
           'TextColor', C_TEXT, 'Color', C_PANEL, ...
           'EdgeColor', C_SUBTEXT, 'FontSize', 8, 'Location','northeast');

    % ---- Plot 3: HRV Tachogram ----
    ax3 = axes('Parent', fig, 'Units','normalized', ...
               'Position', [0.05 0.06 0.92 0.20], ...
               'Color', C_PANEL, 'XColor', C_SUBTEXT, 'YColor', C_SUBTEXT, ...
               'GridColor', [0.25 0.30 0.42], 'GridAlpha', 0.5);
    if length(rr_intervals) > 1
        plot(ax3, r_times(2:end), rr_intervals*1000, 'o-', ...
             'Color', C_HRV, 'LineWidth', 1.2, ...
             'MarkerFaceColor', C_HRV, 'MarkerSize', 5);
        hold(ax3,'on');
        yline(ax3, mean(rr_intervals)*1000, '--', 'Color', [1 1 1 0.5], 'LineWidth', 1.2);
        hold(ax3,'off');
        title(ax3, sprintf('RR Interval Tachogram (HRV)  |  SDNN: %.1f ms', sdnn_ms), ...
              'Color', C_TEXT, 'FontSize', 10, 'FontWeight','bold');
    else
        text(ax3, 0.5, 0.5, 'Insufficient R-peaks for HRV analysis', ...
             'Color', C_SUBTEXT, 'HorizontalAlignment','center', ...
             'Units','normalized', 'FontSize', 11);
        title(ax3, 'RR Interval Tachogram (HRV)', ...
              'Color', C_TEXT, 'FontSize', 10, 'FontWeight','bold');
    end
    xlabel(ax3, 'Time (s)', 'Color', C_SUBTEXT);
    ylabel(ax3, 'RR Interval (ms)', 'Color', C_SUBTEXT);
    xlim(ax3, [0 max(time_raw)]); grid(ax3, 'on');

    fprintf('\n=== CardioSense Pro Results ===\n');
    fprintf('Heart Rate  : %.1f bpm\n', heart_rate);
    fprintf('SDNN        : %.1f ms\n',  sdnn_ms);
    fprintf('R-peaks     : %d\n',       length(r_locs));
    fprintf('Signal SQI  : %s (kurtosis = %.2f)\n', sqi_label, kurt_val);
    fprintf('================================\n');

end

%% =========================================================
%  ARDUINO SKETCH - Upload this separately to your Arduino
%  (copy the lines below into a new Arduino IDE sketch)
% ----------------------------------------------------------
%  const int ECG_PIN  = A0;
%  const int LO_PLUS  = 10;
%  const int LO_MINUS = 11;
%
%  void setup() {
%    Serial.begin(9600);
%    pinMode(LO_PLUS,  INPUT);
%    pinMode(LO_MINUS, INPUT);
%  }
%
%  void loop() {
%    if ((digitalRead(LO_PLUS)==1)||(digitalRead(LO_MINUS)==1)) {
%      Serial.println(0);   // Send 0 if leads off
%    } else {
%      Serial.println(analogRead(A0));
%    }
%    delay(2);  // ~500 Hz sampling rate
%  }
% ==========================================================
