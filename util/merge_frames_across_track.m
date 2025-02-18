function merge_frames_across_track(par,x,y,vel,tracks,compE,compU,vstd)
%=================================================================
% function merge_frames_across_track()
%-----------------------------------------------------------------
% Merge frames across track (assuming they have already been merged
% along-track) by projecting LOS velocities into the average incidence and
% azimuth angle, then removing an offset between adjacent tracks.
%
% These merged velocities are not passed on to the velocity decomposition.
% This is designed as a check of the consistency of the InSAR velocities,
% and so that the structure of the velocity field can be inspected without
% influence from GNSS.
%                                                                  
% INPUT:                                                           
%   par: parameter structure from readparfile.
%   x, y: vectors of longitude and latitude
%   vel: regridded velocities (3D array)
%   tracks: track names (cell array of strings)
%   compE, compU: regridded component vectors (3D arrays)
%   vstd: regridded velocity uncertainties
%   
% Andrew Watson     28-03-2022
%                                                                  
%=================================================================

%% setup

% desired inc and az
av_inc = 39;
av_az_asc = -10;
av_az_desc = -170;

%% deramp vels

% for ii = 1:size(vel,3)
%     vel(:,:,ii) = deramp(x,y,vel(:,:,ii),'poly22');
% end

%% get pass dir

% pre-allocate
tracks_asc = cell(0); tracks_desc = cell(0);
tracks_asc_ind = 1:length(tracks); 
tracks_desc_ind = 1:length(tracks); 

% sort tracks by pass direction 
for ii = 1:length(tracks)
    if tracks{ii}(4) == 'A'
        tracks_asc{end+1} = tracks{ii};
        tracks_desc_ind(ii) = 0;
    elseif tracks{ii}(4) == 'D'
        tracks_desc{end+1} = tracks{ii};
        tracks_asc_ind(ii) = 0;
    end
end

tracks_asc_ind(tracks_asc_ind==0) = [];
tracks_desc_ind(tracks_desc_ind==0) = [];

%% calcualte inc and az from components

% get inc from U
inc = acosd(compU);

% then get az from E
az = acosd(compE./sind(inc))-180;

%% project into fixed az and inc
    
vel(:,:,tracks_asc_ind) = vel(:,:,tracks_asc_ind) ...
    .* ( cosd(av_az_asc-az(:,:,tracks_asc_ind)) .* cosd(av_inc-inc(:,:,tracks_asc_ind)) );

vel(:,:,tracks_desc_ind) = vel(:,:,tracks_desc_ind) ...
    .* ( cosd(av_az_desc-az(:,:,tracks_desc_ind)) .* cosd(av_inc-inc(:,:,tracks_desc_ind)) );

%% minimise difference between adjacent tracks
% Assuming tracks are of similar length, order them by min(x).
% Note, this is going to fail if one track is much longer than the other.

% find min x value
min_x = zeros(1,size(vel,3));
for ii = 1:size(vel,3)
    min_x(ii) = x(find(any(vel(:,:,ii)),1));
end

% split into direction
min_x_asc = min_x(tracks_asc_ind);
min_x_desc = min_x(tracks_desc_ind);

% sort
[~,track_order_asc] = sort(min_x_asc);
[~,track_order_desc] = sort(min_x_desc);

% loop through ascending
for ii = 1:length(track_order_asc)-1
    % calculate residual between overlap and remove nans           
    overlap_resid = vel(:,:,tracks_asc_ind(track_order_asc(ii+1))) ...
        - vel(:,:,tracks_asc_ind(track_order_asc(ii)));
    overlap_resid(isnan(overlap_resid)) = [];

    if isempty(overlap_resid)
        disp('No overlap, skipping. Something has gone wrong with track ordering.')
        continue
    end

    % solve linear inverse for offset
    G = ones(length(overlap_resid),1);
    m = (G'*G)^-1*G'*overlap_resid(:);

    % apply offset
    vel(:,:,tracks_asc_ind(track_order_asc(ii+1))) ...
        = vel(:,:,tracks_asc_ind(track_order_asc(ii+1))) - m;    
end

% loop through descending
for ii = 1:length(track_order_desc)-1
    % calculate residual between overlap and remove nans           
    overlap_resid = vel(:,:,tracks_desc_ind(track_order_desc(ii+1))) ...
        - vel(:,:,tracks_desc_ind(track_order_desc(ii)));
    overlap_resid(isnan(overlap_resid)) = [];

    if isempty(overlap_resid)
        disp('No overlap, skipping. Something has gone wrong with track ordering.')
        continue
    end

    % solve linear inverse for offset
    G = ones(length(overlap_resid),1);
    m = (G'*G)^-1*G'*overlap_resid(:);

    % apply offset
    vel(:,:,tracks_desc_ind(track_order_desc(ii+1))) = vel(:,:,tracks_desc_ind(track_order_desc(ii+1))) - m;    
end

%% take average in overlaps

los_av_asc = mean(vel(:,:,tracks_asc_ind),3,'omitnan');
los_av_desc = mean(vel(:,:,tracks_desc_ind),3,'omitnan');

%% plot

% set plotting parameters
lonlim = [min(x) max(x)];
latlim = [min(y) max(y)];
clim = [par.plt_cmin par.plt_cmax];
load('vik.mat')

% reload borders for ease
if par.plt_borders == 1
    borders = load(par.borders_file);
else
    borders = [];
end

f = figure();
f.Position([1 3 4]) = [600 1600 600];
tiledlayout(1,2,'TileSpacing','compact')

% plot ascending tracks
t(1) = nexttile; hold on
plt_data(x,y,los_av_asc,lonlim,latlim,clim,'Ascending (mm/yr)',[],borders)
colormap(t(1),vik)

% plot descending tracks
t(2) = nexttile; hold on
plt_data(x,y,los_av_desc,lonlim,latlim,clim,'Descending (mm/yr)',[],borders)
colormap(t(2),vik)

%% attempt a simple decomposition with a shared reference area

% new reference area
if par.ref_xmin == 0;
    ref_xmin = min(x(:));
    fprintf('Invalid ref_xmin. Setting to %.2f\n', ref_xmin)
else
    ref_xmin = par.ref_xmin;
end

if par.ref_xmax == 0;
    ref_xmax = max(x(:));
    fprintf('Invalid ref_xmax. Setting to %.2f\n', ref_xmax)
else
    ref_xmax = par.ref_xmax;
end

if par.ref_ymin == 0;
    ref_ymin = min(y(:));
    fprintf('Invalid ref_ymin. Setting to %.2f\n', ref_ymin)
else
    ref_ymin = par.ref_ymin;
end

if par.ref_ymax == 0;
    ref_ymax = max(y(:));
    fprintf('Invalid ref_ymax. Setting to %.2f\n', ref_ymax)
else
    ref_ymax = par.ref_ymax;
end

% get indices
[~,ref_xmin_ind] = min(abs(x-ref_xmin));
[~,ref_xmax_ind] = min(abs(x-ref_xmax));
[~,ref_ymin_ind] = min(abs(y-ref_ymin));
[~,ref_ymax_ind] = min(abs(y-ref_ymax));

% get value and shift
los_av_asc = los_av_asc - mean(los_av_asc(ref_ymin_ind:ref_ymax_ind,ref_xmin_ind:ref_xmax_ind),'all','omitnan');
los_av_desc = los_av_desc - mean(los_av_desc(ref_ymin_ind:ref_ymax_ind,ref_xmin_ind:ref_xmax_ind),'all','omitnan');

% design matrix
G = [sind(av_inc).*-cosd(av_az_asc) cosd(av_inc); sind(av_inc).*-cosd(av_az_desc) cosd(av_inc)];

% pre-al
m_east = nan(size(los_av_asc)); m_up = nan(size(los_av_asc)); 

report_it = round(size(los_av_asc,1)/10);

% loop through pixels and perform decomposition
for jj = 1:size(los_av_asc,1)
    for kk = 1:size(los_av_asc,2)
        
        d = [los_av_asc(jj,kk); los_av_desc(jj,kk)];
        
        if any(isnan(d)) == 1
            continue
        end
      
        % solve
        m = (G'*G)^-1 * G'*d;
               
        % save
        m_east(jj,kk) = m(1);
        m_up(jj,kk) = m(2);    
        
    end
    
    % report progress
    if mod(jj,report_it) == 0
        disp([num2str(jj) '/' num2str(size(los_av_asc,1)) ' rows completed'])
    end
end

clim = [par.plt_cmin par.plt_cmax];

f = figure();
f.Position([1 3 4]) = [600 1600 600];
tiledlayout(1,2,'TileSpacing','compact')

% plot ascending tracks
t(1) = nexttile; hold on
plt_data(x,y,m_east,lonlim,latlim,clim,'East (mm/yr)',[],borders)
colormap(t(1),vik)

% plot descending tracks
t(2) = nexttile; hold on
plt_data(x,y,m_up,lonlim,latlim,clim,'Up (mm/yr)',[],borders)
colormap(t(2),vik)


end

