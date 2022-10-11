function [vel] = ref_to_gnss(par,xx,yy,vel,compE,compN,gnss_E,gnss_N,asc_frames_ind,desc_frames_ind)
%=================================================================
% function ref_to_gnss()
%-----------------------------------------------------------------
% Tie InSAR velocities into a GNSS refernce frame.
% Largely based on the method from Weiss et al. (2020).
% Main steps are:
%   - interpolate GNSS stations velocities into continuous fields
%       (provided as an input)
%   - project GNSS into LOS for each frame/track
%   - calculate residual between InSAR and GNSS
%   - either fit a polynomial to the residual, or apply a filter
%   - subtract this smoothed difference from the InSAR
%                                                                  
% INPUT:                                                           
%   par: parameter structure from readparfile.
%   x, y: vectors of longitude and latitude
%   vel: regridded velocities (3D array)
%   compE, compN, compU: regridded component vectors (3D arrays)
%   vstd: regridded velocity uncertainties
%   asc_frames_ind, desc_frames_ind: indices for ascending and descending
%       frames/tracks
% OUTPUT:    
%   vel: velocities in GNSS reference system
%   
% Andrew Watson     06-06-2022
%                                                                  
%=================================================================

% pre-allocate
nframes = size(vel,3);
% gnss_resid_plane = zeros([size(xx) nframes]);

% coords
x = xx(1,:); y = yy(:,1);

for ii = 1:nframes

    % skip loop if vel is empty (likely because of masking)
    if all(isnan(vel(:,:,ii)),'all')
        disp(['Layer ' num2str(ii) ' of vel is empty after masking, skipping referencing'])
        continue
    end

    % convert gnss fields to los
    gnss_los = (gnss_E.*compE(:,:,ii)) + (gnss_N.*compN(:,:,ii));

    % calculate residual
    vel_tmp = full_nan(vel(:,:,ii));
    
    % mask after deramping (deramp isn't carried forward)
    % use a hardcoded 10 mm/yr limit to remove large signals (mainly
    % subsidence and seismic)
    vel_deramp = deramp(x,y,vel_tmp);
    vel_deramp = vel_deramp - mean(vel_deramp(:),'omitnan');
    vel_mask = vel_deramp>10 | vel_deramp<-10;
    
    vel_tmp(vel_mask) = nan;

    gnss_resid = vel_tmp - gnss_los;
    
    % method switch
    switch par.tie2gnss
        case 1 % polynomial surface
            
            % remove nans
            gnss_xx = xx(~isnan(gnss_resid));
            gnss_yy = yy(~isnan(gnss_resid));
            gnss_resid = gnss_resid(~isnan(gnss_resid));
    
            % centre coords
            midx = (max(gnss_xx) + min(gnss_xx))/2;
            midy = (max(gnss_yy) + min(gnss_yy))/2;
            gnss_xx = gnss_xx - midx ;gnss_yy = gnss_yy - midy;
            all_xx = xx - midx; all_yy = yy - midy;

            % check that an order has been set
            if isempty(par.ref_poly_order)
                error('Must set par.ref_poly_order if using poly for referencing')
            end
            
            % fit polynomial
            if par.ref_poly_order == 1 % 1st order
                G_resid = [ones(length(gnss_xx),1) gnss_xx gnss_yy];
                m_resid = (G_resid'*G_resid)^-1*G_resid'*gnss_resid;
                gnss_resid_plane(:,:,ii) = m_resid(1) + m_resid(2).*all_xx + m_resid(3).*all_yy;
                
            elseif par.ref_poly_order == 2 % 2nd order
                G_resid = [ones(length(gnss_xx),1) gnss_xx gnss_yy gnss_xx.*gnss_yy ...
                    gnss_xx.^2 gnss_yy.^2];
                m_resid = (G_resid'*G_resid)^-1*G_resid'*gnss_resid;
                gnss_resid_plane_loop = m_resid(1) + m_resid(2).*all_xx + m_resid(3).*all_yy ...
                    + m_resid(4).*all_xx.*all_yy + m_resid(5).*all_xx.^2 + m_resid(6).*all_yy.^2;
            end
            
        case 2 % filtering
            
            % make sure filter size is odd
            if mod(par.ref_filter_window_size,2) ~= 1
                error('Filter window size must be an odd number')
            end
            
            % filter gnss residual
            windsize = [par.ref_filter_window_size par.ref_filter_window_size];
            gnss_resid_filtered = ndnanfilter(gnss_resid,'rectwin',windsize);
            
            % reapply nans
            gnss_resid_filtered(isnan(gnss_resid)) = nan;
            
            % store
            gnss_resid_plane_loop = gnss_resid_filtered;
            
    end
    
    % for plotting
    if par.plt_ref_gnss_indv == 1
        vel_orig = full_nan(vel(:,:,ii));
    end
        
    % convert resid_plane to sparse and reapply nans
    gnss_resid_plane_loop(vel(:,:,ii)==0) = 0;
    gnss_resid_plane_loop = sparse(gnss_resid_plane_loop);
    gnss_resid_plane_loop(isnan(vel(:,:,ii))) = nan;
       
    % remove from insar
    vel(:,:,ii) = vel(:,:,ii) - gnss_resid_plane_loop;
    
    % save to sparse
    if ii == 1
        gnss_resid_plane = ndSparse(gnss_resid_plane_loop);
    else
        gnss_resid_plane = cat(3,gnss_resid_plane,gnss_resid_plane_loop);
    end
    
    % optional plotting
    if par.plt_ref_gnss_indv == 1
        
        load('plotting/cpt/vik.mat')
        
        % limits
        clim = [-10 10];
        x = xx(1,:); y = yy(:,1);
        [~,x_ind,y_ind] = crop_nans(vel(:,:,ii),x,y);
        lonlim = x([x_ind(1) x_ind(end)]); latlim = y([y_ind(1) y_ind(end)]);
        
        f = figure();
        f.Position([1 3 4]) = [600 1600 600];
        tiledlayout(1,3,'TileSpacing','compact');

        nexttile; hold on
        imagesc(x,y,vel_orig,'AlphaData',~isnan(vel_orig)); axis xy
        xlim(lonlim); ylim(latlim);
        colorbar; colormap(vik); caxis(clim)
        title('Original InSAR vel')

        nexttile; hold on
        imagesc(x,y,gnss_resid_plane(:,:,ii),'AlphaData',~isnan(gnss_resid_plane(:,:,ii))); axis xy
        xlim(lonlim); ylim(latlim);
        colorbar; colormap(vik); caxis(clim)
        title('Referencing residual')

        nexttile; hold on
        imagesc(x,y,vel(:,:,ii),'AlphaData',~isnan(vel(:,:,ii))); axis xy
        xlim(lonlim); ylim(latlim);
        colorbar; colormap(vik); caxis(clim)
        title('Referenced InSAR')
        
    end
    
    % report progress
    disp([num2str(ii) '/' num2str(nframes) ' complete'])

end

% plot referencing functions
lonlim = [min(x) max(x)];
latlim = [min(y) max(y)];
clim = [-10 10];
load('plotting/cpt/vik.mat')

f = figure();
f.Position([1 3 4]) = [600 1600 600];
t = tiledlayout(1,2,'TileSpacing','compact');
title(t,'Referencing surfaces')

% ascending tracks
t(1) = nexttile; hold on
plt_data(x,y,gnss_resid_plane(:,:,asc_frames_ind),lonlim,latlim,clim,'Ascending (mm/yr)',[],[])
colormap(t(1),vik)

% descending tracks
t(2) = nexttile; hold on
plt_data(x,y,gnss_resid_plane(:,:,desc_frames_ind),lonlim,latlim,clim,'Descending (mm/yr)',[],[])
colormap(t(2),vik)

end