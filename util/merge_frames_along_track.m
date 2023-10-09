function [track_vel,track_compE,track_compN,track_compU,track_vstd,unique_tracks, track_hgt] ...
    = merge_frames_along_track(par,cpt,x,y,vel,frames,compE,compN,compU,vstd, hgt)
%=================================================================
% function merge_frames_along_track()
%-----------------------------------------------------------------
% Merge frames along each track using overlaps, solving for either a static
% offset (merge_tracks_along==1) or a 1st order plane
% (merge_tracks_along==2). 
%                                                                  
% INPUT:                                                           
%   par: parameter structure from readparfile.
%   cpt: structure containing colour palettes
%   x, y: vectors of longitude and latitude
%   vel: regridded velocities (3D array)
%   compE, compN, compU: regridded component vectors (3D arrays)
%   vstd: regridded velocity uncertainties
% OUTPUT:    
%   track_vel: merged velocities for each track (3D array)
%   track_compE, track_compN, track_compU: average component vectors
%   track_vstd: merged velocity uncertainties
%   unique_tracks: track names (cell array of strings)
%   
% Andrew Watson     04-03-2022
%                                                                  
%=================================================================

%% make output directory if saving overlaps is requested

if par.save_overlaps == 1
    if ~exist([par.out_path par.out_prefix '_overlaps'],'dir')
        mkdir([par.out_path par.out_prefix '_overlaps'])
    end
end

%% get unique tracks

% get tracks from frame ids, removing duplicates
tracks = cellfun(@(x) x(1:4), frames, 'UniformOutput', false);
unique_tracks = unique(tracks);

%% merge frames along-track

% pre-allocate
track_vel = nan([size(vel,[1 2]) length(unique_tracks)]);
track_compE = nan(size(track_vel)); track_compN = nan(size(track_vel));
track_compU = nan(size(track_vel)); track_vstd = nan(size(track_vel));
track_hgt = nan([size(hgt,[1 2]) length(unique_tracks)]);

% account for frames that merge into more than one veocity field as a 
% result of empty overlaps
ind_count = 1;

% coords
[xx,yy] = meshgrid(x,y);

% loop through each track
for ii = 1:length(unique_tracks)
    
    disp(['Merging ' unique_tracks{ind_count}])
    
    % get inds for frames on that track
    track_ind = find(cellfun(@(x) ...
        strncmp(unique_tracks{ind_count},x,length(unique_tracks{ind_count})), tracks));
    
    % pre-allocate
    multi_segment = zeros(length(track_ind),2);
    multi_segment_ind = 1;
    overlaps = cell(length(track_ind)-1,1);
    n_ov = 1;
    
    % loop through adjcent pairings along-track
    for jj = 1:length(track_ind)-1
        
        % calculate residual between overlap and remove nans           
        overlap_resid = vel(:,:,track_ind(jj+1)) - vel(:,:,track_ind(jj));
        overlap_invalid_points = isnan(overlap_resid);
        overlap_resid(overlap_invalid_points) = [];
        
        % check frames actually overlap, split if not
        if isempty(overlap_resid)
            disp('No overlap, splitting into multiple segments')

            % save indexes of non-overlapping frames
            multi_segment(multi_segment_ind,:) = [jj jj+1];
            multi_segment_ind = multi_segment_ind + 1;
            continue
        end
        
        % calculate shift
        switch par.merge_tracks_along_func
            case 0 % mean difference               
                vel(:,:,track_ind(jj+1)) = vel(:,:,track_ind(jj+1)) ...
                    - mean(overlap_resid(:),'omitnan');
                               
            case 1 % best fitting ramp                
                % valid coords
                x_overlap = xx(~overlap_invalid_points); y_overlap = yy(~overlap_invalid_points);
                
                % solve lienar inverse for 1st order poly
                G = [ones(length(x_overlap),1) x_overlap y_overlap];
                m = (G'*G)^-1*G'*overlap_resid';
                overlap_plane = m(1) + m(2).*xx + m(3).*yy;
                
                % apply plane
                vel(:,:,track_ind(jj+1)) = vel(:,:,track_ind(jj+1)) - overlap_plane;
                
                
            case 2 % median difference
                vel(:,:,track_ind(jj+1)) = vel(:,:,track_ind(jj+1)) ...
                    - median(overlap_resid(:),'omitnan');
                
            case 3 % modal difference
                vel(:,:,track_ind(jj+1)) = vel(:,:,track_ind(jj+1)) ...
                    - mode(round(overlap_resid(:),1),'all');
                
        end
               
        % save overlap for plotting and/or saving
        if par.plt_merge_along_resid == 1 || par.save_overlaps == 1
            overlaps{n_ov} = vel(:,:,track_ind(jj+1)) - vel(:,:,track_ind(jj));
            n_ov = n_ov + 1;
        end
        
    end

    % save overlaps for histograms
    if par.save_overlaps == 1
        overlaps = overlaps(~cellfun('isempty',overlaps));
        for kk = 1:length(overlaps)
            writematrix(overlaps{kk}(~isnan(overlaps{kk})),...
                [par.out_path par.out_prefix '_overlaps/' unique_tracks{ind_count} '_' num2str(kk) '_along.txt'])
        end
    end
    
    % remove unused rows
    multi_segment(multi_segment(:,1)==0,:) = [];
    
    % plot residuals between overlaps
    if par.plt_merge_along_resid == 1
        
        % pre-al
        overlaps = overlaps(~cellfun('isempty',overlaps));
        overlap_stats = zeros(length(overlaps),2);
        
        % loop through overlaps
        for nn = 1:length(overlaps)
            figure(); tiledlayout(2,1,'TileSpacing','compact')
            [cropped_overlap,~,~,x_crop,y_crop] = crop_nans(overlaps{nn},x,y);
            nexttile(); imagesc(x_crop,y_crop,cropped_overlap,'AlphaData',~isnan(cropped_overlap)); 
            colorbar; axis xy
            nexttile(); histogram(overlaps{nn});
            title(['Mean = ' num2str(round(mean(cropped_overlap(:),'omitnan'),2)) ...
                ', SD = ' num2str(round(std(cropped_overlap(:),'omitnan'),2)) ...
                ', Median = ' num2str(round(median(cropped_overlap(:),'omitnan'),2))])
            overlap_stats(nn,:) = [mean(cropped_overlap(:),'omitnan') std(cropped_overlap(:),'omitnan')];
        end
        
    end
    
    % merge frames in track into single velocity field
    if par.merge_tracks_along == 2
        
        if isempty(multi_segment)
            % take the weighted mean of overlap and store new vel
            track_weights = 1 ./ vstd(:,:,track_ind);            
            track_vel(:,:,ind_count) = sum(vel(:,:,track_ind).*track_weights,3,'omitnan') ...
                ./ sum(track_weights,3,'omitnan');

            % merge component vectors
            track_compE(:,:,ind_count) = mean(compE(:,:,track_ind),3,'omitnan');
            track_compN(:,:,ind_count) = mean(compN(:,:,track_ind),3,'omitnan');
            track_compU(:,:,ind_count) = mean(compU(:,:,track_ind),3,'omitnan');

            % merge pixel uncertainties
            track_vstd(:,:,ind_count) = 1 ./ sqrt( sum(track_weights,3,'omitnan') );
            
            % merge hgts
            track_hgt(:,:,ind_count) = mean(hgt(:,:,track_ind),3,'omitnan');
            
        else
            % number of segments
            n_seg = size(multi_segment,1) + 1;
            
            % convert multi_segment to indexes
            multi_segment = [1; multi_segment(:); length(track_ind)];
            
            % add extra layers onto track arrays
            track_vel = cat(3,track_vel,nan([size(vel,[1 2]) n_seg-1]));
            track_compE = cat(3,track_compE,nan([size(vel,[1 2]) n_seg-1]));
            track_compN = cat(3,track_compN,nan([size(vel,[1 2]) n_seg-1]));
            track_compU = cat(3,track_compU,nan([size(vel,[1 2]) n_seg-1]));
            track_vstd = cat(3,track_vstd,nan([size(vel,[1 2]) n_seg-1]));
            track_hgt = cat(3,track_hgt,nan([size(vel,[1 2]) n_seg-1]));
            
            % duplicate track name
            repelem_vec = ones(1,length(unique_tracks));
            repelem_vec(ind_count) = n_seg;
            unique_tracks = repelem(unique_tracks,repelem_vec);
            
            % save segments to different array layers
            ind_count_inc = 0;
            for kk = 1:2:length(multi_segment)
                
                % indices for this segment
                track_ind_seg = track_ind(multi_segment(kk):multi_segment(kk+1));
                
                % take weighted mean of subset of frames on track             
                track_weights = 1 ./ vstd(:,:,track_ind_seg);            
                track_vel(:,:,ind_count+ind_count_inc) ...
                    = sum(vel(:,:,track_ind_seg).*track_weights,3,'omitnan') ...
                    ./ sum(track_weights,3,'omitnan');
                
                track_compE(:,:,ind_count+ind_count_inc) ...
                    = mean(compE(:,:,track_ind_seg),3,'omitnan');
                track_compN(:,:,ind_count+ind_count_inc) ...
                    = mean(compN(:,:,track_ind_seg),3,'omitnan');
                track_compU(:,:,ind_count+ind_count_inc) ...
                    = mean(compU(:,:,track_ind_seg),3,'omitnan');
                
                track_hgt(:,:,ind_count+ind_count_inc) ...
                    = mean(hgt(:,:,track_ind_seg),3,'omitnan');
                
                % weighted uncertainties
                track_vstd(:,:,ind_count+ind_count_inc) = 1 ./ sqrt( sum(track_weights,3,'omitnan') );
                
                % increment counter
                ind_count_inc = ind_count_inc + 1;
                
            end
            
            % increment counter
            ind_count = ind_count + (n_seg-1);
            
        end
    end
    
    % plot original velocities and merged result
    if par.plt_merge_along_corr == 1 || par.plt_merge_along_corr == 2
        
        % plot original frames
        f1 = figure();
        tiledlayout(1,length(track_ind),'TileSpacing','compact')
        for kk = 1:length(track_ind)
            nexttile
            col_ind = find(any(~isnan(vel(:,:,track_ind(kk))),1));
            row_ind = find(any(~isnan(vel(:,:,track_ind(kk))),2));        
            imagesc(x,y,vel(:,:,track_ind(kk)),'AlphaData',~isnan(vel(:,:,track_ind(kk))))
            xlim([x(col_ind(1)) x(col_ind(end))])
            ylim([y(row_ind(1)) y(row_ind(end))])
            caxis([par.plt_cmin par.plt_cmax])
            colorbar
            axis xy
        end

        % plot merged result
        f2 = figure();
        col_ind = find(any(~isnan(track_vel(:,:,ii)),1));
        row_ind = find(any(~isnan(track_vel(:,:,ii)),2));
        imagesc(x,y,track_vel(:,:,ii),'AlphaData',~isnan(track_vel(:,:,ii)));
        xlim([x(col_ind(1)) x(col_ind(end))])
        ylim([y(row_ind(1)) y(row_ind(end))])
        caxis([par.plt_cmin par.plt_cmax])
        colorbar
        axis xy
        
        % weight for the figures to be closed to avoid bombarding the user
        % when using a large number of frames
        if par.plt_merge_along_corr == 2
            waitfor(f1); waitfor(f2)
        end
        
    end
    
    % report progress
    disp([num2str(ind_count) '/' num2str(length(unique_tracks)) ' complete'])
    
    % increment
    ind_count = ind_count + 1;
    
    % clear
    clear overlaps
    
end

% if not merging overlaps, then duplicate variables for output
if par.merge_tracks_along == 1
    track_vel = vel; track_vstd = vstd;
    track_compE = compE; track_compN = compN; track_compU = compU;
    track_hgt = hgt;
end

%% plot merged tracks

% make sure tracks have been merged
if par.plt_merge_tracks == 1 && par.merge_tracks_along == 1
    warning(["Merge track plot requested, but merge_tracks_along ~= 2."])
end

if par.plt_merge_tracks == 1 && par.merge_tracks_along == 2
    
    % asc and desc indices
    unique_tracks_asc_ind = find(cellfun(@(x) strncmp('A',x(4),4), unique_tracks));
    unique_tracks_desc_ind = find(cellfun(@(x) strncmp('D',x(4),4), unique_tracks));
    
    % set plotting parameters
    lonlim = [min(x) max(x)];
    latlim = [min(y) max(y)];
    clim = [par.plt_cmin par.plt_cmax];
    
    % reload borders for ease
    if par.plt_borders == 1
        borders = load(par.borders_file);
    else
        borders = [];
    end
    
    f = figure();
    f.Position([1 3 4]) = [600 1600 600];
    t = tiledlayout(1,2,'TileSpacing','compact');
    title(t,'Along-track merge')
    
    % plot ascending tracks
    t(1) = nexttile; hold on
    plt_data(x,y,track_vel(:,:,unique_tracks_asc_ind),lonlim,latlim,clim,'Ascending (mm/yr)',[],borders)
    colormap(t(1),cpt.vik)
    
    % plot descending tracks
    t(2) = nexttile; hold on
    plt_data(x,y,track_vel(:,:,unique_tracks_desc_ind),lonlim,latlim,clim,'Descending (mm/yr)',[],borders)
    colormap(t(2),cpt.vik)

end

end
